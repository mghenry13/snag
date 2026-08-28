#!/bin/bash
# Build Snag.app (+ snag-mcp) and optionally relaunch: ./build.sh run
# Signs with Developer ID when available (hardened runtime, Sparkle-ready),
# otherwise falls back to ad-hoc so anyone can build from source.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="build/Snag.app"
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Snag "$APP/Contents/MacOS/Snag"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R extension "$APP/Contents/Resources/extension"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Snag" 2>/dev/null || true

cp .build/release/snag-mcp build/snag-mcp

if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp -s "$IDENTITY" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime --timestamp -s "$IDENTITY" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime --timestamp -s "$IDENTITY" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime --timestamp -s "$IDENTITY" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
    codesign --force --options runtime --timestamp -s "$IDENTITY" \
        "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp -s "$IDENTITY" build/snag-mcp
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
else
    echo "No Developer ID found — ad-hoc signing"
    codesign --force --deep -s - "$APP"
    codesign --force -s - build/snag-mcp
fi

echo "Built $APP and build/snag-mcp"
if [ "$1" == "run" ]; then
    pkill -x Snag 2>/dev/null || true
    sleep 0.5
    open "$APP"
    echo "Launched Snag"
fi
