#!/usr/bin/env bash
# Build WinHub.app (via build.sh) and package it into a drag-to-install DMG:
# the app plus a symlink to /Applications. Output: dist/WinHub-<version>.dmg
set -euo pipefail

APP_NAME="WinHub"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/$APP_NAME.app"
DIST="$ROOT/dist"

# Build the app first.
"$ROOT/build.sh" release

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "▸ Staging DMG contents…"
cp -R "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DMG"

echo "▸ Building ${DMG}…"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "✓ Built: $DMG"
echo "  shasum: $(shasum -a 256 "$DMG" | awk '{print $1}')"
