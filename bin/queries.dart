const insertPostTemplate = '''INSERT INTO post (
  Title,
  Link,
  Descript,
  PubDate
)
  VALUES
###VALUE###;''';

const checkExist = '''SELECT *
FROM post
LIMIT 1;''';

const createDB = '''DROP TABLE IF EXISTS post;

CREATE TABLE post (
  Title     TEXT NOT NULL,
  Link      TEXT NOT NULL PRIMARY KEY,
  Descript  TEXT NOT NULL,
  PubDate   TEXT NOT NULL,
  uri       TEXT,
  cid       TEXT
)''';

const selectToSkeet = '''SELECT
  Title,
  Link,
  Descript,
  PubDate
FROM post
WHERE
  uri IS NULL
  AND PubDate >= '###DATE###'
ORDER BY
  PubDate ASC;''';
