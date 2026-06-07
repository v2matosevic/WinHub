#!/usr/bin/env bash
# Build WinHub, assemble WinHub.app, and code-sign it.
# Usage: ./build.sh [debug|release]   (default: release)
set -euo pipefail

APP_NAME="WinHub"
BUNDLE_ID="hr.version2.winhub"
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP_DIR="$ROOT/$APP_NAME.app"

echo "▸ Building $APP_NAME ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
[ -f "$ROOT/Resources/$APP_NAME.icns" ] && cp "$ROOT/Resources/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Version2 · MIT License</string>
</dict>
</plist>
PLIST

# Prefer a stable self-signed identity so TCC grants (Accessibility, Screen
# Recording) survive rebuilds — ad-hoc "-" changes the code hash every build and
# resets those grants. See Scripts/dev_identity.sh. WINHUB_SIGN_ID overrides both.
WINHUB_KC="$HOME/Library/Keychains/winhub-dev.keychain-db"
if [ -n "${WINHUB_SIGN_ID:-}" ]; then
    SIGN_ID="$WINHUB_SIGN_ID"
elif [ -f "$WINHUB_KC" ] && security find-identity -p codesigning -v "$WINHUB_KC" 2>/dev/null | grep -q "WinHub Dev"; then
    SIGN_ID="WinHub Dev"
    security unlock-keychain -p winhub-dev "$WINHUB_KC" 2>/dev/null || true
    # codesign resolves the identity via the keychain search list — ensure ours is in it.
    if ! security list-keychains -d user | grep -q "winhub-dev.keychain"; then
        security list-keychains -d user -s "$WINHUB_KC" $(security list-keychains -d user | xargs -n1)
    fi
else
    SIGN_ID="-"
fi

echo "▸ Code signing ($([ "$SIGN_ID" = "-" ] && echo ad-hoc || echo "$SIGN_ID"))…"
codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1
codesign --verify --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /' || true

echo "✓ Built: $APP_DIR"
echo "  Run with:  open \"$APP_DIR\""
