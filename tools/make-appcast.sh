#!/bin/bash
# make-appcast.sh <zip> <sig-attrs> — writes updates/public/appcast.xml
# for the newest release. Reads version numbers from Info.plist.
set -e
cd "$(dirname "$0")/.."
ZIP="$1"; SIG_ATTRS="$2"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
SIZE=$(stat -f%z "$ZIP")
DATE=$(date -R)
FEED_BASE="https://snag-updates.mghenry13.workers.dev"
mkdir -p updates/public
cat > updates/public/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Snag</title>
    <item>
      <title>Snag $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILDNUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$FEED_BASE/$(basename "$ZIP")" length="$SIZE" type="application/octet-stream" $SIG_ATTRS />
    </item>
  </channel>
</rss>
XML
cp "$ZIP" updates/public/
echo "appcast written for $VERSION (build $BUILDNUM)"
