#!/bin/bash
# Builds Keywright.app with Swift Package Manager and installs it into /Applications (override with
# APP=/path/Keywright.app).
#
# Signing: macOS keys TCC grants (Accessibility, Screen Recording, Input Monitoring) on the signing
# identity + bundle id, so sign every build with the same identity or the grants are lost on each
# rebuild. Set KEYWRIGHT_SIGN_IDENTITY (a certificate name or SHA-1 from
# `security find-identity -v -p codesigning`), or put `KEYWRIGHT_SIGN_IDENTITY=…` in a
# git-ignored `.signing` file next to this script. Without one, the build is signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .signing ] && source .signing
APP="${APP:-/Applications/Keywright.app}"
IDENTITY="${KEYWRIGHT_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "note: no KEYWRIGHT_SIGN_IDENTITY, signing ad hoc (permissions must be granted again after each rebuild)" >&2
fi
swift build -c release --product Keywright
swift build -c release --product keywright-check
BINDIR="$(swift build -c release --product Keywright --show-bin-path)"
BIN="$BINDIR/Keywright"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate: swift scripts/make-icon.swift
cp "$BIN" "$APP/Contents/MacOS/Keywright"
# The permission check, run inside a terminal (menu: Copy terminal check command). Signed first:
# nested code has to be signed before the bundle around it.
cp "$BINDIR/keywright-check" "$APP/Contents/Resources/keywright-check"
# Hardened runtime (--options runtime): macOS then ignores DYLD_* variables, refuses libraries
# not signed by the same team, and blocks debuggers. Without it, any process running as the user
# could inject code into Keywright and use its permissions with no lock, token or Touch ID.
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Resources/keywright-check"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
