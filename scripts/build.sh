#!/usr/bin/env bash
# Reproducible build of CursorVoice.app from a fresh checkout.
# Uses swiftc + iconutil + codesign — no Xcode required (just CLT).
#
# Builds into /tmp to avoid iCloud Drive xattrs that break hardened
# runtime signing. The final .app + .dmg are copied back into $ROOT/build/
# for convenience.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CursorVoice"
DISPLAY_NAME="Cursor Voice"
BUNDLE_ID="com.cursorvoice.app"
VERSION="${VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.6.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DEPLOY_TARGET="14.0"

# Build outside iCloud-managed folders.
WORK_DIR="/tmp/cursorvoice-build"
APP_BUNDLE="$WORK_DIR/$APP_NAME.app"
ICONSET="$WORK_DIR/AppIcon.iconset"
ICON_SRC="$ROOT/Sources/CursorVoice/Assets.xcassets/AppIcon.appiconset"
ENTITLEMENTS="$ROOT/entitlements.plist"
OUTPUT_DIR="$ROOT/build"

echo "==> Clean"
rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$OUTPUT_DIR"

echo "==> Compile Swift sources"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
find "$ROOT/Sources/CursorVoice" -name "*.swift" -print0 | xargs -0 swiftc \
  -O \
  -target arm64-apple-macos$DEPLOY_TARGET \
  -sdk "$SDK" \
  -parse-as-library \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Generate .icns from PNG iconset"
mkdir -p "$ICONSET"
cp "$ICON_SRC/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$ICON_SRC/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$ICON_SRC/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Bundle menu-bar icon resources"
cp "$ICON_SRC/icon_32.png" "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png"
cp "$ICON_SRC/icon_64.png" "$APP_BUNDLE/Contents/Resources/MenuBarIcon@2x.png"

echo "==> Write Info.plist"
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT-licensed open source.</string>
    <key>NSMicrophoneUsageDescription</key><string>Cursor Voice listens to your voice so you can talk to the assistant.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Cursor Voice uses on-device speech recognition to detect the wake word.</string>
    <key>NSAppleEventsUsageDescription</key><string>Cursor Voice runs AppleScript to perform tasks across your apps.</string>
    <key>NSDesktopFolderUsageDescription</key><string>Cursor Voice may read files in Desktop you ask the assistant about.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Cursor Voice may read files in Documents you ask the assistant about.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Cursor Voice may read files in Downloads you ask the assistant about.</string>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key><string>${BUNDLE_ID}.install</string>
        <key>CFBundleURLSchemes</key><array><string>cursorvoice</string></array>
      </dict>
    </array>
</dict>
</plist>
EOF

echo "==> Strip extended attributes"
/usr/bin/xattr -cr "$APP_BUNDLE"

# Sign with a STABLE identity so the codesign "designated requirement" pins the
# certificate (constant across builds) rather than the cdhash (changes every
# build). macOS TCC keys mic/screen/accessibility grants on that requirement —
# ad-hoc signing makes every update look like a new app and forces re-granting.
# Falls back to ad-hoc if the identity isn't present (e.g. a fresh checkout).
SIGN_IDENTITY="${CV_SIGN_IDENTITY:-Cursor Voice Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> Code sign (stable identity: $SIGN_IDENTITY)"
  SIGN_ARG="$SIGN_IDENTITY"
else
  echo "==> Code sign (ad-hoc — '$SIGN_IDENTITY' not in keychain; permissions will reset each build)"
  SIGN_ARG="-"
fi
codesign --force --deep --sign "$SIGN_ARG" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$APP_BUNDLE"

echo "==> Verify"
codesign --verify --verbose=2 "$APP_BUNDLE"

echo "==> Copy to $OUTPUT_DIR (for convenience)"
ditto --noextattr --noqtn "$APP_BUNDLE" "$OUTPUT_DIR/$APP_NAME.app"

echo
echo "Built: $APP_BUNDLE  ($VERSION)"
du -sh "$APP_BUNDLE"
echo "Mirror: $OUTPUT_DIR/$APP_NAME.app"
