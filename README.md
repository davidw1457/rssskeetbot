A command line utility to read an RSS 2.0 feed and skeet it to Bluesky

The program will read the contents of config.json (in the same directory as the 
binary) then read the rss feed, store any posts in a database, skeet any new
posts and exit. If you have multiple feeds and/or accounts, you can store them 
all in the json and it will go through them all. Check the included config.json
for the expected format.

The rss post will create 3+ skeets with the following formats
Skeet #1:
{Title}
Skeet #2:
Link: {Link}
Date: {PubDate}
Skeet #3:
Description: {Description}

Because Bluesky limits skeets to 300 characters, this may end up being more than
three skeets when posted.

Because it runs once and exits, it is recommended to run it with a scheduler 
such as cron on Linux or Task Scheduler on Windows.

Note the program was written and tested on Zorin OS and Raspberry Pi OS. It 
should work on any desktop platform supported by Dart, but no guarantees for 
macOS or Windows. If you try it there and get a bug reach out.

If you have any questions, reach out to 
[@davidw1457.bsky.social](https://bsky.app/profile/davidw1457.bsky.social)

Thank you to [Shinya Kato](https://github.com/myConsciousness) for his work 
creating the [Dart Bluesky API](https://atprotodart.com)

