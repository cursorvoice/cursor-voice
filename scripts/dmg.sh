#!/usr/bin/env bash
# Pack the built .app into a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CursorVoice"
VERSION="${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.6.0)}"

BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
STAGING="$BUILD_DIR/dmg-staging"

if [ ! -d "$APP_BUNDLE" ]; then
  echo "App not built — run scripts/build.sh first." >&2
  exit 1
fi

# Guard against packaging a stale build: the app bundle's version MUST match the
# VERSION we're naming the DMG after. (Forgetting to rebuild after bumping VERSION
# once shipped a 0.7.1-named DMG containing a 0.7.0 app → endless update banner.)
APP_VER="$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")"
if [ "$APP_VER" != "$VERSION" ]; then
  echo "Version mismatch: build/$APP_NAME.app is $APP_VER but VERSION is $VERSION." >&2
  echo "Re-run scripts/build.sh so the app is stamped $VERSION before packaging." >&2
  exit 1
fi

echo "==> Stage DMG contents"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil create"
hdiutil create \
  -srcfolder "$STAGING" \
  -volname "$APP_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

# SHA256 for the Homebrew cask.
SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

echo
echo "DMG:    $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "SHA256: $SHA"
