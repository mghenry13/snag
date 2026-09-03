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
    echo ""
    echo "  ⚠️  NOT NOTARIZED — Sparkle auto-updates WILL FAIL for everyone."
    echo "  Gatekeeper rejects unnotarized apps, so the updater cannot launch"
    echo "  the downloaded build. One-time setup, then re-run this script:"
    echo ""
    echo "    xcrun notarytool store-credentials snag-notary \\"
    echo "      --apple-id YOUR_APPLE_ID --team-id VKXK2JE3PE --password APP_SPECIFIC_PASSWORD"
    echo ""
fi

# Gatekeeper must accept the build or updates break on arrival.
if spctl -a -t exec "build/Snag.app" 2>/dev/null; then
    echo "Gatekeeper: accepted ✓"
else
    echo "Gatekeeper: REJECTED — auto-updates will fail until this build is notarized."
fi

SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
SIG_ATTRS=$("$SIGN" "$ZIP" | tr -d '\n')
./tools/make-appcast.sh "$ZIP" "$SIG_ATTRS"

(cd updates && npx wrangler deploy)

if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" --clobber
else
    # A stable-named copy so releases/latest/download/Snag.zip never rots — the
# versioned name changes every release and breaks any link that hardcodes it.
STABLE_ZIP="$(dirname "$ZIP")/Snag.zip"
cp "$ZIP" "$STABLE_ZIP"

gh release create "v$VERSION" "$ZIP" "$STABLE_ZIP" --title "Snag $VERSION" \
        --notes "Signed build. Unzip and drop Snag.app in /Applications. Auto-updates via Sparkle after this."
fi
echo "Released $VERSION (build $BUILDNUM) -> $FEED_BASE/appcast.xml + GitHub"
