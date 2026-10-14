#!/bin/zsh
# Builds ShotPark.app (universal: Apple Silicon + Intel) and optionally installs it to /Applications.
#   SHOTPARK_ARCH=arm64 ./build.sh   → single-arch build (faster, for local iteration)
#   ./build.sh            → build/ShotPark.app
#   ./build.sh --install  → also copies to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

NAME="ShotPark"
APP="build/$NAME.app"

ARCHS="${SHOTPARK_ARCH:-arm64 x86_64}"
# SwiftPM with only the Command Line Tools can't do a multi-arch build in one go (needs Xcode's
# xcbuild), so build each slice separately and glue them with lipo.
# The output directory depends on the toolchain (.build/<arch>-apple-macosx/release with the
# classic driver, .build/out/Products/Release with the newer one), so ask SwiftPM where it put
# each slice and copy it aside before building the next one.
mkdir -p build
SLICES=()
for a in ${=ARCHS}; do
  echo "▶ swift build (release, $a)"
  swift build -c release --arch "$a"
  BINDIR="$(swift build -c release --arch "$a" --show-bin-path)"
  [ -f "$BINDIR/$NAME" ] || { echo "빌드 실패: $BINDIR/$NAME 이(가) 없습니다"; exit 1; }
  # Make sure this really is a fresh build of the current sources, not a stale file.
  if [ -n "$(find Sources -name '*.swift' -newer "$BINDIR/$NAME")" ]; then
    echo "빌드 실패: $BINDIR/$NAME 이(가) 소스보다 오래됐습니다"; exit 1
  fi
  cp "$BINDIR/$NAME" "build/$NAME.$a"
  SLICES+=("build/$NAME.$a")
done
if [ ${#SLICES[@]} -gt 1 ]; then
  echo "▶ lipo → universal"
  lipo -create -output "build/$NAME.universal" "${SLICES[@]}"
  BIN="build/$NAME.universal"
else
  BIN="${SLICES[1]}"
fi

echo "▶ app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Info.plist "$APP/Contents/Info.plist"
[ -d Resources ] && cp -R Resources/. "$APP/Contents/Resources/"   # localized Info.plist strings etc.
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

# 'ShotPark Developer' 라는 자체 서명 인증서가 키체인에 있으면 그걸로, 없으면 ad-hoc 으로 서명합니다.
# (ad-hoc 은 빌드마다 서명이 바뀌어 화면 기록 권한을 매번 다시 물어봅니다.)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ShotPark Developer"; then
  echo "▶ codesign (ShotPark Developer)"
  codesign --force --deep --sign "ShotPark Developer" --identifier ai.worxphere.suseok.shotpark "$APP"
else
  echo "▶ codesign (ad-hoc)"
  codesign --force --deep --sign - --identifier ai.worxphere.suseok.shotpark "$APP"
fi
file "$APP/Contents/MacOS/$NAME"

if [[ "${1:-}" == "--install" ]]; then
  echo "▶ install → /Applications/$NAME.app"
  pkill -x "$NAME" 2>/dev/null || true
  pkill -x SwiftShot 2>/dev/null || true          # 이전 이름의 앱 정리
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$NAME" >/dev/null || break; sleep 0.3; done   # wait for it to quit
  rm -rf "/Applications/$NAME.app" /Applications/SwiftShot.app
  cp -R "$APP" "/Applications/$NAME.app"
  open "/Applications/$NAME.app"
  echo "✓ 설치 및 실행 완료. 메뉴 막대의 카메라 아이콘을 확인하세요."
fi
