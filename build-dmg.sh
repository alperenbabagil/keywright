#!/bin/bash
# Builds a signed Keywright.app and packs it into dist/Keywright-<version>.dmg (drag-to-Applications).
# Signing identity: see build.sh. With KEYWRIGHT_NOTARY_PROFILE set (a `xcrun notarytool
# store-credentials` profile, also read from .signing), the DMG is notarized and stapled, so a
# downloaded copy opens without a Gatekeeper warning.
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
if [ -n "${KEYWRIGHT_NOTARY_PROFILE:-}" ]; then
  [ "$IDENTITY" = "-" ] && { echo "Notarizing needs a Developer ID identity" >&2; exit 1; }
  xcrun notarytool submit "$DMG" --keychain-profile "$KEYWRIGHT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Built $DMG"
