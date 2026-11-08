#!/bin/bash
# Builds MacWright.app with Swift Package Manager and installs it into /Applications (override with
# APP=/path/MacWright.app).
#
# Signing: macOS keys TCC grants (Accessibility, Screen Recording, Input Monitoring) on the signing
# identity + bundle id, so sign every build with the same identity or the grants are lost on each
# rebuild. Set MACWRIGHT_SIGN_IDENTITY (a certificate name or SHA-1 from
# `security find-identity -v -p codesigning`), or put `MACWRIGHT_SIGN_IDENTITY=…` in a
# git-ignored `.signing` file next to this script. Without one, the build is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .signing ] && source .signing
APP="${APP:-/Applications/MacWright.app}"
IDENTITY="${MACWRIGHT_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "note: no MACWRIGHT_SIGN_IDENTITY, signing ad hoc (permissions must be granted again after each rebuild)" >&2
fi
swift build -c release --product MacWright
swift build -c release --product macwright-check
BINDIR="$(swift build -c release --product MacWright --show-bin-path)"
BIN="$BINDIR/MacWright"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate: swift scripts/make-icon.swift
cp "$BIN" "$APP/Contents/MacOS/MacWright"
# The permission check, run inside a terminal (menu: Copy terminal check command). Signed first:
# nested code has to be signed before the bundle around it.
cp "$BINDIR/macwright-check" "$APP/Contents/Resources/macwright-check"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/macwright-check"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
