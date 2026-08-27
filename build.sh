#!/bin/bash
# Build Snag.app and (re)launch it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/Snag.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snag "$APP/Contents/MacOS/Snag"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"

cp .build/release/snag-mcp build/snag-mcp
codesign --force -s - build/snag-mcp

echo "Built $APP and build/snag-mcp"
if [ "$1" == "run" ]; then
    pkill -x Snag 2>/dev/null || true
    sleep 0.5
    open "$APP"
    echo "Launched Snag"
fi
