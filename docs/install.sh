#!/bin/sh
# ShotPark one-line installer — https://shotpark.site
#   curl -fsSL https://shotpark.site/install.sh | sh
# Downloads the latest release, installs to /Applications (or $SHOTPARK_DEST), clears the quarantine flag, launches.
# Everything runs inside main() so a partially downloaded script never executes.
set -eu

main() {
  REPO="chiyodad/shotpark"
  APP="ShotPark.app"
  DEST="${SHOTPARK_DEST:-/Applications}"

  if [ "$(uname -s)" != "Darwin" ]; then echo "ShotPark is a macOS app."; exit 1; fi
  MAJOR=$(sw_vers -productVersion | cut -d. -f1)
  if [ "$MAJOR" -lt 13 ]; then echo "ShotPark needs macOS 13 or later (this Mac runs $(sw_vers -productVersion))."; exit 1; fi

  if command -v brew >/dev/null 2>&1 && brew list --cask shotpark >/dev/null 2>&1; then
    echo "ShotPark was installed with Homebrew. Update it with:"
    echo "  brew upgrade --cask chiyodad/tap/shotpark"
    exit 0
  fi

  if [ ! -d "$DEST" ] || [ ! -w "$DEST" ]; then
    echo "Can't write to $DEST. Run with SHOTPARK_DEST=\"\$HOME/Applications\" (create it first), or use Homebrew:"
    echo "  brew install --cask chiyodad/tap/shotpark"
    exit 1
  fi

  echo "▶ Finding the latest ShotPark release…"
  # The releases/latest redirect isn't subject to the unauthenticated API rate limit.
  TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed -E 's#.*/tag/##')
  VER=${TAG#v}
  case "$VER" in
    [0-9]*.[0-9]*) ;;
    *) echo "Could not find the latest release."; exit 1 ;;
  esac
  URL="https://github.com/$REPO/releases/download/$TAG/ShotPark-$VER.zip"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "▶ Downloading ShotPark ${VER}…"
  curl -fSL --progress-bar "$URL" -o "$TMP/ShotPark.zip"
  if curl -fsSL "$URL.sha256" -o "$TMP/sum" 2>/dev/null; then
    WANT=$(cut -d' ' -f1 "$TMP/sum")
    HAVE=$(shasum -a 256 "$TMP/ShotPark.zip" | cut -d' ' -f1)
    [ "$WANT" = "$HAVE" ] || { echo "Checksum mismatch — download corrupted. Try again."; exit 1; }
  fi
  ditto -x -k "$TMP/ShotPark.zip" "$TMP/unpacked"
  [ -d "$TMP/unpacked/$APP" ] || { echo "Unexpected archive layout."; exit 1; }

  if pgrep -x ShotPark >/dev/null 2>&1; then
    echo "▶ Quitting the running ShotPark…"
    pkill -x ShotPark || true
    i=0
    while pgrep -x ShotPark >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
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
  echo "  The first time it opens, macOS asks for Screen Recording permission: enable ShotPark, then quit & relaunch the app once."
}

main "$@"
