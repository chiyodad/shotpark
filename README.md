# ShotPark

Lightshot 스타일의 영역 캡처 + 주석 도구. Apple Silicon 네이티브 (Swift / AppKit, 외부 의존성 없음).

## 빌드 & 설치

```sh
./build.sh --install     # 빌드 → build/ShotPark.app → /Applications 에 복사 후 실행
```

요구 사항: macOS 13 이상, Xcode Command Line Tools (`xcode-select --install`).

## 사용법

| 동작 | 키 |
|---|---|
| 영역 캡처 시작 | **⌘⇧9** 기본값 — 설정(⌘,)에서 변경 가능 (메뉴 막대 아이콘 → 영역 캡처 도 가능) |
| 전체 화면 선택 | ⌘A |
| 펜 / 선 / 화살표 / 사각형 / 타원 / 마커 / 텍스트 | P / L / A / R / E / M / T |
| 선택(이동·크기조절) 모드 | V (또는 활성 도구 다시 클릭) |
| 클립보드로 복사 후 닫기 | ⌘C 또는 Enter |
| PNG 로 저장 | ⌘S — 설정한 저장 폴더에 바로 저장(기본), 또는 저장 창 표시 |
| 공유 (Claude · Slack · 카카오톡 · 시스템 공유 시트) | ⌘⇧S 또는 툴바 공유 버튼 |
| 실행 취소 | ⌘Z |
| 취소 | Esc (선택 중이면 선택만 해제, 한 번 더 누르면 종료) / 우클릭 |

첫 실행 시 **시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록** 에서 ShotPark 을 허용해야 합니다.
허용 후 앱을 한 번 종료했다가 다시 실행하세요.

## 설정

메뉴 막대 아이콘 → **설정…** (또는 ⌘,)

- **캡처 단축키**: 박스를 클릭하고 원하는 조합을 누르면 즉시 적용됩니다 (⌘/⌥/⌃ 중 하나 포함 또는 F키).
- **저장 폴더**: 기본은 데스크탑. "변경…"으로 아무 폴더나 지정할 수 있습니다.
- **바로 저장**: 켜두면 ⌘S 가 확인 창 없이 지정 폴더에 저장하고 상단에 알림을 띄웁니다(알림 클릭 → Finder). 끄면 저장 창이 뜹니다.

공유 동작: 이미지를 클립보드에 복사한 뒤 해당 앱을 열어 파일을 넘깁니다. 앱이 파일을 받지 않으면 앱만 활성화되므로 ⌘V 로 붙여넣으면 됩니다.

## 구조

- `Sources/ShotPark/AppDelegate.swift` – 메뉴 막대 아이템, 메인 메뉴, 전역 단축키, 세션 시작
- `HotKey.swift` – Carbon `RegisterEventHotKey` (손쉬운 사용 권한 불필요)
- `ScreenCapture.swift` – ScreenCaptureKit (macOS 14+) / `CGDisplayCreateImage` 폴백
- `CaptureSession.swift` – 모니터별 오버레이 창, 전역 ⌘C/Enter 처리, 클립보드/저장/공유
- `CaptureView.swift` – 영역 선택, 핸들, 주석 캔버스, 키보드 처리, 결과 렌더링
- `Shapes.swift` – 주석 모델 + 렌더러 (화면/내보내기 동일 코드)
- `ToolbarView.swift` – 플로팅 툴바, 색상 팔레트
- `Settings.swift` – 설정 저장(UserDefaults), 단축키 레코더, 설정 창, 저장 알림 토스트
