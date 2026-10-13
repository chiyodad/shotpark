#!/bin/sh
# Build, zip, publish a GitHub release (macOS + Windows zips), and update the Homebrew cask.
#   ./release.sh            # uses CFBundleShortVersionString from Info.plist
#   ./release.sh --notes "…"
set -eu
cd "$(dirname "$0")"
REPO="chiyodad/shotpark"
TAP="chiyodad/homebrew-tap"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
NOTES="ShotPark $VER"
[ "${1:-}" = "--notes" ] && NOTES="$2"

./build.sh
mkdir -p dist
ZIP="dist/ShotPark-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/ShotPark.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "▶ $ZIP  sha256=$SHA"

# Windows build (cross-published from the Mac): single-file exes, same version number.
# Version-free names keep https://github.com/$REPO/releases/latest/download/ShotPark-Windows-x64.zip stable.
DOTNET=$(command -v dotnet || echo "$HOME/.dotnet/dotnet")
WINZIPS=""
if [ -x "$DOTNET" ]; then
  for RID in x64 arm64; do
    OUT="dist/win-$RID"
    rm -rf "$OUT"
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" publish windows/src/ShotPark.Win/ShotPark.Win.csproj \
      -c Release -r "win-$RID" --self-contained true -p:Version="$VER" \
      -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
      -p:EnableCompressionInSingleFile=true -p:DebugType=none -o "$OUT" >/dev/null
    WZ="dist/ShotPark-Windows-$RID.zip"
    rm -f "$WZ"
    (cd "$OUT" && zip -q "../ShotPark-Windows-$RID.zip" ShotPark.exe)
    WINZIPS="$WINZIPS $WZ"
    echo "▶ $WZ"
  done
else
  echo "⚠ dotnet not found — skipping the Windows build"
fi

git tag -f "v$VER"
git push -q origin main && git push -q -f origin "v$VER"
if gh release view "v$VER" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VER" "$ZIP" $WINZIPS -R "$REPO" --clobber
else
  gh release create "v$VER" "$ZIP" $WINZIPS -R "$REPO" --title "ShotPark $VER" --notes "$NOTES"
fi

# Homebrew cask in the tap repo (edited via the GitHub API, no clone needed)
CASK=$(cat <<RB
cask "shotpark" do
  version "$VER"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/ShotPark-#{version}.zip"
  name "ShotPark"
  desc "Region screenshot, annotation and sharing tool for macOS"
  homepage "https://shotpark.site/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "ShotPark.app"

  # Not notarized: clear the quarantine flag so Gatekeeper doesn't block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ShotPark.app"],
                   must_succeed: false
  end

  caveats <<~EOS
    First capture asks for Screen Recording permission: enable ShotPark in
    System Settings → Privacy & Security → Screen & System Audio Recording, then quit and relaunch it once.
  EOS

  zap trash: [
    "~/Library/Preferences/ai.worxphere.suseok.shotpark.plist",
  ]
end
RB
)
SHA_OLD=$(gh api "repos/$TAP/contents/Casks/shotpark.rb" --jq .sha 2>/dev/null || true)
printf '%s\n' "$CASK" | base64 | tr -d '\n' > /tmp/shotpark_cask.b64
gh api -X PUT "repos/$TAP/contents/Casks/shotpark.rb" \
  -f message="shotpark $VER" -f content="$(cat /tmp/shotpark_cask.b64)" ${SHA_OLD:+-f sha="$SHA_OLD"} --jq '.content.path' 
echo "✓ Released v$VER and updated the Homebrew cask."
