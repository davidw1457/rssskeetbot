import 'dart:convert';
import 'dart:io';

import 'package:dart_rss/dart_rss.dart';
import 'package:html/parser.dart' as parser;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:sqlite3/sqlite3.dart';
import 'package:bluesky/atproto.dart' as at;
import 'package:bluesky/bluesky.dart' as bsky;
import 'package:bluesky_text/bluesky_text.dart' as bskytxt;

import 'queries.dart' as qry;

final log = Logger('RSSSkeetBot');

void main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    for (final arg in arguments) {
      if (arg == 'debug') {
        Logger.root.level = Level.ALL;
        recordStackTraceAtLevel = Level.SEVERE;
      }
    }
  }
  Logger.root.onRecord.listen((record) {
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  log.info("getting accounts");

  final accts = _loadAccts();

  if (accts.isEmpty) {
    log.severe('no valid accounts');
    exit(1);
  }

  var totalSkeets = 0;

  for (final acct in accts) {
    log.info("getting posts for ${acct['uri']}");

    final rssPosts = await _getRSSPosts(acct['uri']!);
    if (rssPosts.isEmpty) {
      log.severe("no posts returned by rss feed");
      continue;
    }

    log.info("opening database");
    final Database db;
    try {
      db = _openDatabase(acct['database']!);
    } catch (e) {
      log.severe(e);
      continue;
    }

    log.info("updating databse");
    final toPost = _insertPosts(db, rssPosts);

    log.info("posting updates");
    if (toPost) {
      log.info("there are things to post");
      final skeetCount =
          await _skeetPosts(db, acct['username']!, acct['password']!);
      print("$skeetCount updates posted for ${acct['username']}");
      totalSkeets += skeetCount;
    } else {
      log.info("nothing to post");
    }
  }
  log.info("$totalSkeets total skeets");
  exit(0);
}

Future<Map<String, Map>> _getRSSPosts(String uriString) async {
  log.fine('getting posts');

  final uri = Uri.parse(uriString);
  final http.Response resp;

  log.fine('executing GET');
  try {
    resp = await http.get(uri);
  } catch (e) {
    log.warning(e);
    return {};
  }

  log.fine('checking statuscode');
  if (resp.statusCode < 200 || resp.statusCode > 299) {
    log.warning('error. statuscode: ${resp.statusCode} body: ${resp.body}');
    return {};
  }

  final Map<String, Map> rssData = {};
  final channel = RssFeed.parse(resp.body);
  for (final item in channel.items) {
    if (item.link != null) {
      final Map<String, String> post = {
        "title": item.title ?? '',
        "descript": item.description ?? '',
        "pubDate": item.pubDate ?? '',
      };
      rssData[item.link!] = post;
    }
  }

  return rssData;
}

Database _openDatabase(String databaseName) {
  final String homeDir = Platform.environment['HOME'] ?? '';
  final sep = Platform.pathSeparator;

  final databaseDir = Directory('$homeDir$sep.databases');
  if (!databaseDir.existsSync()) {
    databaseDir.createSync();
  }

  final db = sqlite3.open('${databaseDir.path}$sep$databaseName');

  if (_isNew(db)) {
    _initializeDB(db);
  }

  return db;
}

bool _isNew(Database db) {
  final ResultSet results;
  try {
    results = db.select(qry.checkExist);
  } on SqliteException catch (e) {
    if (e.message == 'no such table: recalls') {
      return true;
    }
    log.severe(e);
    rethrow;
  } catch (e) {
    log.severe(e);
    rethrow;
  }
  return results.isEmpty;
}

void _initializeDB(Database db) {
  try {
    db.execute(qry.createDB);
  } catch (e) {
    log.severe(e);
    rethrow;
  }
}

bool _insertPosts(Database db, Map<String, Map> posts) {
  var newPosts = false;
  for (final k in posts.keys) {
    final String postValue = _postValue(k, posts[k]!);
    final String qryInsertPost =
        qry.insertPostTemplate.replaceAll('###VALUE###', postValue);
    try {
      db.execute(qryInsertPost);
    } on SqliteException catch (e) {
      if (e.explanation == 'constraint failed (code 1555)') {
        continue;
      }

      log.severe(e);
      log.fine(qryInsertPost);

      continue;
    } catch (e) {
      log.severe(e);
      log.fine(qryInsertPost);

      continue;
    }
    newPosts = true;
  }
  return newPosts;
}

String _postValue(String l, Map v) {
  var pubDate = _toFormattedDateString(v['pubDate']);
  final List<String> values = [
    _sanitizeSqlString(v['title']),
    _sanitizeSqlString(l),
    _sanitizeSqlString(v['descript']),
    _sanitizeSqlString(pubDate),
  ];
  final String value = "('${values.join("','")}')";
  return value;
}

String _sanitizeSqlString(String s) {
  return s.replaceAll("'", "''");
}

String _toFormattedDateString(String d) {
  var fields = d.split(' ');
  var year = fields[3];
  var month = _months[fields[2]];
  var day = fields[1].padLeft(2, '0');
  return '$year-$month-$day';
}

Future<int> _skeetPosts(Database db, String username, String password) async {
  var posted = 0;
  final ResultSet results;
  try {
    final threshold = DateTime.now().subtract(const Duration(days: 7));
    final year = '${threshold.year}';
    final month = '${threshold.month}'.padLeft(2, '0');
    final day = '${threshold.day}'.padLeft(2, '0');
    final thresholdStr = '$year-$month-$day';
    final qrySelectToPost =
        qry.selectToSkeet.replaceAll('###DATE###', thresholdStr);
    results = db.select(qrySelectToPost);
  } catch (e) {
    print('_postUpdates: $e');
    rethrow;
  }

  final session = await at.createSession(
    identifier: username,
    password: password,
  );

  final bskysesh = bsky.Bluesky.fromSession(session.data);

  for (final r in results) {
    if (r['Title'] == null || r['Title'] == '') {
      log.warning('no title: $r');
      continue;
    }
    final List<at.StrongRef> titlerefs = [];
    for (final p in _postTitles) {
      final post = _createPost(p, r);
      if (post.value.isEmpty) {
        continue;
      }
      for (final s in post.split()) {
        final bsky.ReplyRef? reply;
        if (titlerefs.isNotEmpty) {
          reply = bsky.ReplyRef(
            root: titlerefs.first,
            parent: titlerefs.last,
          );
        } else {
          reply = null;
        }

        final facets = await s.entities.toFacets();
        final strongRef = await bskysesh.feed.post(
            text: s.value,
            reply: reply,
            facets: facets.map(bsky.Facet.fromJson).toList());
        titlerefs.add(strongRef.data);

        ++posted;
        log.finest(post.value);
        sleep(Duration(seconds: 2));
      }
    }
    _updateRecall(r['Link'], titlerefs.first.cid, titlerefs.first.uri.href, db);
  }

  return posted;
}

void _updateRecall(String link, String cid, String uri, Database db) {
  final updateQuery = '''UPDATE recalls
SET
  uri = '$uri',
  cid = '$cid'
WHERE
  Link = '$link';''';
  try {
    db.execute(updateQuery);
  } on SqliteException catch (e) {
    print('_updateRecall: $e');
    print(updateQuery);
    rethrow;
  }
}

bskytxt.BlueskyText _createPost(List<List<String>> titles, Row r) {
  StringBuffer postText = StringBuffer();
  for (final t in titles) {
    final field = t[0];
    final header = t[1];
    String? rawText;
    try {
      rawText = parser.parseFragment(r[field]).text;
    } catch (e) {
      print(e);
      print('field: $field');
      print('fragment: ${r[field]}');
    }
    if (rawText != null && rawText != '') {
      rawText.replaceAll('  ', ' ');
      rawText.replaceAll('\n\n', '\n');
      if (header != '') {
        if (postText.isNotEmpty) {
          postText.write('\n');
        }
        postText.write('$header: ');
      }
      postText.write(rawText);
    }
  }
  final text = bskytxt.BlueskyText(postText.toString());
  return text;
}

const Map<String, String> _months = {
  'Jan': '01',
  'Feb': '02',
  'Mar': '03',
  'Apr': '04',
  'May': '05',
  'Jun': '06',
  'Jul': '07',
  'Aug': '08',
  'Sep': '09',
  'Oct': '10',
  'Nov': '11',
  'Dec': '12',
};

const List<List<List<String>>> _postTitles = [
  [
    ['Title', ''],
  ],
  [
    ['Link', 'Link'],
    ['PubDate', 'Date'],
  ],
  [
    ['Descript', 'Description'],
  ],
];

List<Map<String, String>> _loadAccts() {
  log.fine('getting accounts');

  final List<Map<String, String>> acctsToCheck;
  try {
    final configFile = File('config.json');
    final configFileContents = configFile.readAsStringSync();
    acctsToCheck = jsonDecode(configFileContents) as List<Map<String, String>>;
  } catch (e) {
    log.severe(e);
    rethrow;
  }

  final List<Map<String, String>> accts = [];

  for (final acct in acctsToCheck) {
    if (!_isValidAcct(acct)) {
      continue;
    }
    accts.add(acct);
  }

  log.fine('found ${accts.length} accounts');
  return accts;
}

bool _isValidAcct(acct) {
  var valid = true;
  if (acct['uri'] == null || acct['uri'] == '') {
    log.warning('account missing uri: $acct');
    valid = false;
  } else if (acct['username'] == null || acct['username'] == '') {
    log.warning('account missing username: $acct');
    valid = false;
  } else if (acct['password'] == null || acct['password'] == '') {
    log.warning('account missing password: $acct');
    valid = false;
  } else if (acct['database'] == null || acct['database'] == '') {
    log.warning('account missing database: $acct');
    valid = false;
  }

  return valid;
}
