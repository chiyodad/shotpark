import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var session: CaptureSession?
    private var loginItem: NSMenuItem!
    private var captureItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        registerHotKey()

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }

        if !ScreenCapture.hasPermission() {
            // Triggers the system prompt + adds the app to the Screen Recording list.
            ScreenCapture.requestPermission()
        }

        // Pre-fetch display info so the first ⌘⇧9 is as fast as the rest; refresh when screens change.
        ScreenCapture.prewarm()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in ScreenCapture.prewarm() }

        handleDemoEnvironment()
    }

    /// Developer aid for taking documentation screenshots:
    ///   SHOTPARK_SETTINGS=1                → open the settings window on launch
    ///   SHOTPARK_DEMO="x,y,w,h"            → start a capture and pre-fill a selection (+ sample
    ///                                        annotations) at the given rect, in points, top-left origin
    ///                                        of the main screen. The overlay stays up until Esc.
    private func handleDemoEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if env["SHOTPARK_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.openSettings() }
        }
        guard let spec = env["SHOTPARK_DEMO"] else { return }
        let nums = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4, let screen = NSScreen.main else { return }
        let r = CGRect(x: nums[0], y: screen.frame.height - nums[1] - nums[3], width: nums[2], height: nums[3])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startCapture() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let view = self?.session?.primaryView else { return }
            let color = ColorPaletteView.colors[0]
            // SHOTPARK_DEMO_SHAPES="ellipse:x1,y1,x2,y2;arrow:x1,y1,x2,y2;rect:...;text:x,y,label"
            // coordinates in points, top-left origin of the main screen.
            let H = screen.frame.height
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: H - y) }
            var shapes: [Shape] = []
            for item in (env["SHOTPARK_DEMO_SHAPES"] ?? "").split(separator: ";") {
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let args = parts[1].split(separator: ",").map { String($0) }
                let v = args.compactMap { Double($0) }
                switch parts[0] {
                case "ellipse" where v.count >= 4:
                    shapes.append(Shape(tool: .ellipse, points: [pt(v[0], v[1]), pt(v[2], v[3])], color: color, lineWidth: 3))
                case "rect" where v.count >= 4:
                    shapes.append(Shape(tool: .rect, points: [pt(v[0], v[1]), pt(v[2], v[3])], color: color, lineWidth: 3))
                case "arrow" where v.count >= 4:
                    shapes.append(Shape(tool: .arrow, points: [pt(v[0], v[1]), pt(v[2], v[3])], color: color, lineWidth: 3))
                case "line" where v.count >= 4:
                    shapes.append(Shape(tool: .line, points: [pt(v[0], v[1]), pt(v[2], v[3])], color: color, lineWidth: 3))
                case "text" where v.count >= 2 && args.count >= 3:
                    // text:x,y,label[,size]
                    let size = (args.count >= 4 ? Double(args[args.count - 1]) : nil) ?? 20
                    let label = args.count >= 4 && Double(args[args.count - 1]) != nil ? args[2..<(args.count - 1)].joined(separator: ",") : args[2...].joined(separator: ",")
                    shapes.append(Shape(tool: .text, points: [pt(v[0], v[1])], color: color, lineWidth: 3,
                                        text: label, fontSize: CGFloat(size), textStyle: Preferences.textStyle,
                                        boxColor: Preferences.boxColor, boxAlpha: Preferences.boxAlpha))
                default: break
                }
            }
            view.applyDemo(selection: r, shapes: shapes)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        startCapture()
        return false
    }

    // MARK: hotkey

    private func registerHotKey() {
        let spec = Settings.hotKey
        hotKey = nil // unregister previous
        hotKey = HotKey(keyCode: spec.keyCode, modifiers: spec.carbonModifiers) { [weak self] in
            self?.startCapture()
        }
        captureItem?.keyEquivalent = spec.keyEquivalent
        captureItem?.keyEquivalentModifierMask = spec.nsModifiers
        captureItem?.title = spec.keyEquivalent.isEmpty ? L("영역 캡처  (\(spec.display))", "Capture Region  (\(spec.display))") : L("영역 캡처", "Capture Region")
        statusItem?.button?.toolTip = L("ShotPark — \(spec.display) 로 영역 캡처", "ShotPark — \(spec.display) to capture a region")
    }

    // MARK: menus

    /// Minimal main menu so ⌘Q / ⌘, / ⌘C·⌘V in text fields work (the app is menu-bar only).
    private func setupMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("설정…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("ShotPark 종료", "Quit ShotPark"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("편집", "Edit"))
        edit.addItem(withTitle: L("실행 취소", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("잘라내기", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("복사", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("붙여넣기", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("전체 선택", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("윈도우", "Window"))
        windowMenu.addItem(withTitle: L("닫기", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "ShotPark")
            btn.image?.isTemplate = true
        }

        let menu = NSMenu()
        captureItem = NSMenuItem(title: L("영역 캡처", "Capture Region"), action: #selector(captureAction), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("설정… (단축키 · 저장 폴더)", "Settings… (Hotkey · Save Folder)"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let folder = NSMenuItem(title: L("저장 폴더 열기", "Open Save Folder"), action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        loginItem = NSMenuItem(title: L("로그인 시 자동 실행", "Launch at Login"), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let perm = NSMenuItem(title: L("화면 기록 권한 설정…", "Screen Recording Permission…"), action: #selector(openPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(.separator())

        let about = NSMenuItem(title: L("ShotPark 정보", "About ShotPark"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: L("ShotPark 종료", "Quit ShotPark"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func captureAction() {
        // Let the menu close first so it is not in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.startCapture() }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Settings.saveFolder])
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openPermission() {
        ScreenCapture.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "ShotPark"
        alert.informativeText = L10n.isKorean ? """
        가벼운 네이티브 Apple Silicon 영역 캡처 도구

        \(Settings.hotKey.display)  영역 캡처 시작 (설정에서 변경 가능)
        드래그  영역 선택 · 핸들로 크기 조절 · 안쪽 드래그로 이동
        P 펜 · L 선 · A 화살표 · R 사각형 · E 타원 · M 마커 · T 텍스트 · N 번호 · S 이모지 도장 · V 선택
        Enter / ⌘C  클립보드로 복사   ⌘S  PNG 저장   ⌘⇧S  공유(Claude·Slack·카카오톡)
        ⌘Z  실행 취소   Esc  취소

        저장 폴더: \((Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
        """ : """
        A lightweight native Apple Silicon region capture tool — a Lightshot alternative for Mac

        \(Settings.hotKey.display)  start a region capture (change it in Settings)
        Drag to select · handles to resize · drag inside to move
        P pen · L line · A arrow · R rectangle · E ellipse · M marker · T text · N number · S emoji stamp · V select
        Enter / ⌘C  copy to clipboard   ⌘S  save PNG   ⌘⇧S  share (Claude · Slack · KakaoTalk)
        ⌘Z  undo   Esc  cancel

        Save folder: \((Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
        """
        alert.addButton(withTitle: L("확인", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: capture

    func startCapture() {
        guard session == nil else { return }
        let s = CaptureSession { [weak self] in
            self?.session = nil
        }
        session = s
        Task { @MainActor in
            await s.start()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
