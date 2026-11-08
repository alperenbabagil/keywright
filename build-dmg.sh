#!/bin/bash
# Builds a signed MacWright.app and packs it into dist/MacWright-<version>.dmg (drag-to-Applications).
# Signing identity: see build.sh.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .signing ] && source .signing
IDENTITY="${MACWRIGHT_SIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/MacWright.app" MACWRIGHT_SIGN_IDENTITY="$IDENTITY" ./build.sh
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/MacWright-$VERSION.dmg"
hdiutil create -volname "MacWright $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[ "$IDENTITY" != "-" ] && codesign --force --sign "$IDENTITY" "$DMG"
echo "Built $DMG"
