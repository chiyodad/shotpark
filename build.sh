#!/bin/zsh
# Builds ShotPark.app (Apple Silicon native) and optionally installs it to /Applications.
#   ./build.sh            → build/ShotPark.app
#   ./build.sh --install  → also copies to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

NAME="ShotPark"
APP="build/$NAME.app"

echo "▶ swift build (release, arm64)"
swift build -c release --arch arm64
BIN=".build/arm64-apple-macosx/release/$NAME"
[ -f "$BIN" ] || BIN=".build/release/$NAME"
[ -f "$BIN" ] || { echo "빌드 실패: 바이너리를 찾을 수 없습니다"; exit 1; }

echo "▶ app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

[ -f icon.png ] || swift makeicon.swift || true
if [ -f icon.png ]; then
  echo "▶ icon"
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶ codesign (ad-hoc)"
codesign --force --deep --sign - --identifier ai.worxphere.suseok.shotpark "$APP"
file "$APP/Contents/MacOS/$NAME"

if [[ "${1:-}" == "--install" ]]; then
  echo "▶ install → /Applications/$NAME.app"
  pkill -x "$NAME" 2>/dev/null || true
  pkill -x SwiftShot 2>/dev/null || true          # 이전 이름의 앱 정리
  rm -rf "/Applications/$NAME.app" /Applications/SwiftShot.app
  cp -R "$APP" "/Applications/$NAME.app"
  open "/Applications/$NAME.app"
  echo "✓ 설치 및 실행 완료. 메뉴 막대의 카메라 아이콘을 확인하세요."
fi
