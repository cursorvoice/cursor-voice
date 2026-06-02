#!/usr/bin/env bash
# Cursor Voice one-line installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/cursorvoice/cursor-voice/main/install.sh | bash
#
# What it does:
#   1. Verifies macOS 14+ on Apple Silicon
#   2. Downloads the latest DMG release from GitHub
#   3. Mounts it and copies CursorVoice.app to /Applications
#   4. Removes the quarantine attribute so Gatekeeper doesn't block first launch
#   5. Launches the app
set -euo pipefail

REPO="cursorvoice/cursor-voice"
APP_NAME="CursorVoice"

#--- sanity checks -----------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
  echo "Cursor Voice is macOS-only." >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  echo "Cursor Voice requires Apple Silicon (arm64). Detected: $(uname -m)" >&2
  exit 1
fi
MAJOR=$(sw_vers -productVersion | awk -F. '{print $1}')
if [ "$MAJOR" -lt 14 ]; then
  echo "Cursor Voice requires macOS 14 (Sonoma) or later. Detected: $(sw_vers -productVersion)" >&2
  exit 1
fi

#--- find latest release -----------------------------------------------------
echo "==> Fetching latest release metadata"
LATEST_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest")
TAG=$(printf '%s' "$LATEST_JSON" | awk -F'"' '/"tag_name":/ { print $4; exit }')
if [ -z "$TAG" ]; then
  echo "Could not find a release in $REPO" >&2
  exit 1
fi
VERSION="${TAG#v}"
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/${APP_NAME}-${VERSION}.dmg"

#--- download ----------------------------------------------------------------
TMP="$(mktemp -d /tmp/cursor-voice-install.XXXXXX)"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT
DMG="$TMP/${APP_NAME}.dmg"

echo "==> Downloading ${APP_NAME} ${TAG}"
curl -fL --progress-bar "$DMG_URL" -o "$DMG"

#--- mount + copy ------------------------------------------------------------
echo "==> Mounting"
MNT="$(hdiutil attach -nobrowse -noautoopen "$DMG" | awk '/Apple_HFS|Apple_APFS/ {for(i=NF;i>=1;i--){if($i ~ /^\//){print $i; exit}}}')"
if [ -z "$MNT" ] || [ ! -d "$MNT/${APP_NAME}.app" ]; then
  echo "Mount failed or app missing in DMG." >&2
  exit 1
fi

DEST="/Applications/${APP_NAME}.app"
if [ -d "$DEST" ]; then
  echo "==> Replacing existing $DEST"
  rm -rf "$DEST"
fi

echo "==> Copying to /Applications"
cp -R "$MNT/${APP_NAME}.app" "$DEST"

#--- strip quarantine (we're ad-hoc signed, Gatekeeper would block first run)
echo "==> Removing quarantine attribute"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

#--- launch ------------------------------------------------------------------
echo "==> Done. Launching ${APP_NAME}"
open -a "$DEST"

cat <<NEXT

  Look in your menu bar for the colored aurora orb.
  Click it → Settings… → paste your OpenAI API key.
  Default hotkey: ⌃⌥/   (configurable in Settings)

NEXT
