#!/bin/bash
# Cut a Snag release: build signed, zip, (notarize if profile exists),
# Sparkle-sign, publish appcast + zip to the updates Worker, GitHub release.
set -e
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Info.plist)
ZIP="build/Snag-$VERSION.zip"
FEED_BASE="https://snag-updates.mghenry13.workers.dev"

./build.sh

# Notarize when the one-time 'snag-notary' keychain profile exists.
ditto -c -k --keepParent build/Snag.app "$ZIP"
if xcrun notarytool history --keychain-profile snag-notary >/dev/null 2>&1; then
    echo "Notarizing..."
    xcrun notarytool submit "$ZIP" --keychain-profile snag-notary --wait
    xcrun stapler staple build/Snag.app
    rm "$ZIP"
    ditto -c -k --keepParent build/Snag.app "$ZIP"
else
    echo "No 'snag-notary' profile — skipping notarization (one-time setup:"
    echo "  xcrun notarytool store-credentials snag-notary --apple-id YOU --team-id VKXK2JE3PE --password APP_SPECIFIC)"
fi

SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
SIG_ATTRS=$("$SIGN" "$ZIP" | tr -d '\n')
./tools/make-appcast.sh "$ZIP" "$SIG_ATTRS"

(cd updates && npx wrangler deploy)

if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    gh release create "v$VERSION" "$ZIP" --title "Snag $VERSION" \
        --notes "Signed build. Unzip and drop Snag.app in /Applications. Auto-updates via Sparkle after this."
fi
echo "Released $VERSION (build $BUILDNUM) -> $FEED_BASE/appcast.xml + GitHub"
