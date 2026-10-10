#!/bin/sh
# Build, zip, publish a GitHub release, and update the Homebrew cask.
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

git tag -f "v$VER"
git push -q origin main "v$VER"
if gh release view "v$VER" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VER" "$ZIP" -R "$REPO" --clobber
else
  gh release create "v$VER" "$ZIP" -R "$REPO" --title "ShotPark $VER" --notes "$NOTES"
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

  depends_on arch: :arm64
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
