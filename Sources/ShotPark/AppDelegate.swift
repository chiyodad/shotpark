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
                    shapes.append(Shape(tool: .text, points: [pt(v[0], v[1])], color: color, lineWidth: 3,
                                        text: args[2...].joined(separator: ","), fontSize: 20))
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
        captureItem?.title = spec.keyEquivalent.isEmpty ? "영역 캡처  (\(spec.display))" : "영역 캡처"
        statusItem?.button?.toolTip = "ShotPark — \(spec.display) 로 영역 캡처"
    }

    // MARK: menus

    /// Minimal main menu so ⌘Q / ⌘, / ⌘C·⌘V in text fields work (the app is menu-bar only).
    private func setupMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "ShotPark 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        captureItem = NSMenuItem(title: "영역 캡처", action: #selector(captureAction), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "설정… (단축키 · 저장 폴더)", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let folder = NSMenuItem(title: "저장 폴더 열기", action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        loginItem = NSMenuItem(title: "로그인 시 자동 실행", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let perm = NSMenuItem(title: "화면 기록 권한 설정…", action: #selector(openPermission), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "ShotPark 정보", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "ShotPark 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        alert.informativeText = """
        Lightshot 스타일의 네이티브 Apple Silicon 캡처 도구

        \(Settings.hotKey.display)  영역 캡처 시작 (설정에서 변경 가능)
        드래그  영역 선택 · 핸들로 크기 조절 · 안쪽 드래그로 이동
        P 펜 · L 선 · A 화살표 · R 사각형 · E 타원 · M 마커 · T 텍스트 · V 선택
        Enter / ⌘C  클립보드로 복사   ⌘S  PNG 저장   ⌘⇧S  공유(Claude·Slack·카카오톡)
        ⌘Z  실행 취소   Esc  취소

        저장 폴더: \((Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
        """
        alert.addButton(withTitle: "확인")
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
