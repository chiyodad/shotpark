#!/bin/sh
# ShotPark one-line installer — https://shotpark.site
#   curl -fsSL https://shotpark.site/install.sh | sh
# Downloads the latest release, installs to /Applications, clears the quarantine flag, launches.
set -eu

REPO="chiyodad/shotpark"
APP="ShotPark.app"
DEST="/Applications"

if [ "$(uname -s)" != "Darwin" ]; then echo "ShotPark is a macOS app."; exit 1; fi

echo "▶ Finding the latest ShotPark release…"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep '"browser_download_url"' | grep -o 'https://[^"]*ShotPark-[0-9.]*\.zip' | head -1)
[ -n "$URL" ] || { echo "Could not find a release asset."; exit 1; }
VER=$(echo "$URL" | sed -E 's/.*ShotPark-([0-9.]+)\.zip/\1/')

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "▶ Downloading ShotPark ${VER}…"
curl -fsSL "$URL" -o "$TMP/ShotPark.zip"
ditto -x -k "$TMP/ShotPark.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/$APP" ] || { echo "Unexpected archive layout."; exit 1; }

if pgrep -x ShotPark >/dev/null 2>&1; then
  echo "▶ Quitting the running ShotPark…"
  pkill -x ShotPark || true; sleep 1
fi

echo "▶ Installing to $DEST/${APP}…"
rm -rf "$DEST/$APP"
ditto "$TMP/unpacked/$APP" "$DEST/$APP"

echo "▶ Clearing the quarantine flag (so Gatekeeper doesn't block an unsigned app)…"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "▶ Launching…"
open "$DEST/$APP"
echo
echo "✓ ShotPark ${VER} installed. Press ⌘⇧9 to capture."
echo "  First capture asks for Screen Recording permission: enable ShotPark, then quit & relaunch the app once."
