#!/bin/bash
# Builds a signed Keywright.app and packs it into dist/Keywright-<version>.dmg (drag-to-Applications).
# Signing identity: see build.sh.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .signing ] && source .signing
IDENTITY="${KEYWRIGHT_SIGN_IDENTITY:--}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Keywright.app" KEYWRIGHT_SIGN_IDENTITY="$IDENTITY" ./build.sh
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/Keywright-$VERSION.dmg"
hdiutil create -volname "Keywright $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[ "$IDENTITY" != "-" ] && codesign --force --sign "$IDENTITY" "$DMG"
echo "Built $DMG"
