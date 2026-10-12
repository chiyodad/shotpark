import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var historyHotKey: HotKey?
    private var session: CaptureSession?
    private var loginItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var historyItem: NSMenuItem?
    private var pinsItem: NSMenuItem!
    private var updateItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        registerHotKey()
        if ProcessInfo.processInfo.environment["SHOTPARK_SELFTEST"] != "1" { ClipboardHistory.shared.start() }

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
        }
        NotificationCenter.default.addObserver(forName: .updateAvailabilityChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshUpdateItem()
        }
        if ProcessInfo.processInfo.environment["SHOTPARK_SELFTEST"] != "1" { UpdateChecker.shared.checkDailyIfNeeded() }

        if !ScreenCapture.hasPermission() {
            // Triggers the system prompt + adds the app to the Screen Recording list.
            ScreenCapture.requestPermission()
        }
        if ProcessInfo.processInfo.environment["SHOTPARK_SELFTEST"] != "1", ProcessInfo.processInfo.environment["SHOTPARK_DEMO"] == nil {
            WelcomeWindowController.showIfFirstLaunch()
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
        if env["SHOTPARK_WELCOME"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WelcomeWindowController.shared.show() }
        }
        if env["SHOTPARK_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.openSettings() }
        }
        if env["SHOTPARK_RENDERTEST"] == "1" {
            // Renders the settings window and a mosaic/blur sample to /tmp for visual review, then quits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                func save(_ v: NSView, _ path: String) {
                    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let v = SettingsWindowController.shared.window?.contentView?.superview { save(v, "/tmp/sp-settings.png") }
                    let bar = StrokeOptionsView()
                    bar.showsDash = true; bar.showsFill = true; bar.fill = 1; bar.fillAlpha = 0.45; bar.color = .systemRed
                    let holder = NSWindow(contentRect: NSRect(origin: .zero, size: bar.frame.size), styleMask: [.borderless], backing: .buffered, defer: false)
                    holder.contentView = bar
                    save(bar, "/tmp/sp-strokebar.png")
                    let sample = NSImage(size: NSSize(width: 600, height: 200), flipped: false) { r in
                        NSColor.white.setFill(); r.fill()
                        NSAttributedString(string: "홍길동 010-1234-5678\nhong@example.com", attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 20, y: 60))
                        return true
                    }
                    guard let cg = sample.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(1) }
                    let lv = CaptureView(frame: NSRect(x: 0, y: 0, width: 600, height: 200), screenshot: cg)
                    if let rep = lv.debugLoupeSnapshot(at: CGPoint(x: 60, y: 125)) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sp-loupe.png"))
                    }
                    if let pretty = Beautify.apply(to: cg, scale: 1, background: 1, padding: 1, shadow: true, rounded: true) {
                        try? NSBitmapImageRep(cgImage: pretty).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sp-beautify.png"))
                    }
                    let bd = MosaicBackdrop(screenshot: cg, viewSize: CGSize(width: 600, height: 200))
                    let out = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { _ in
                        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                        for (row, (style, level)) in [(MosaicStyle.pixelate, 1), (.pixelate, 2), (.blur, 1)].enumerated() {
                            ctx.saveGState()
                            ctx.translateBy(x: 0, y: CGFloat(2 - row) * 200)
                            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 600, height: 200))
                            ShapeRenderer.backdrop = bd
                            var sh = Shape(tool: .mosaic, points: [CGPoint(x: 10, y: 40), CGPoint(x: 420, y: 160)], color: .red, lineWidth: 2)
                            sh.mosaicStyle = style; sh.mosaicLevel = level
                            ShapeRenderer.draw(sh, in: ctx)
                            ctx.restoreGState()
                        }
                        return true
                    }
                    if let t = out.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sp-mosaic.png"))
                    }
                    print("RENDERED"); exit(0)
                }
            }
            return
        }
        if env["SHOTPARK_CLIPTEST"] == "1", env["SHOTPARK_CLIPDIR"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.runClipboardTest() }
            return
        }
        if env["SHOTPARK_PANELTEST"] == "1" {
            // Opens the "+ Add image" panel during a capture and reports which windows are on top.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startCapture() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let view = self.session?.primaryView else { print("no view"); exit(2) }
                let t = Timer(timeInterval: 2.0, repeats: false) { _ in
                    let pid = ProcessInfo.processInfo.processIdentifier
                    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
                    for w in list.prefix(12) {
                        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
                        let opid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                        let layer = w[kCGWindowLayer as String] as? Int ?? 0
                        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
                        print("WIN owner=\(owner) mine=\(opid == pid) layer=\(layer) bounds=\(b["Width"] ?? 0)x\(b["Height"] ?? 0)")
                    }
                    print("modalKey=\(NSApp.modalWindow?.isKeyWindow ?? false) modalWindow=\(String(describing: NSApp.modalWindow)) level=\(NSApp.modalWindow?.level.rawValue ?? -1) visible=\(NSApp.modalWindow?.isVisible ?? false)")
                    NSApp.abortModal()
                    DispatchQueue.main.async { self.session?.cancel(); exit(0) }
                }
                RunLoop.main.add(t, forMode: .common)
                RunLoop.main.add(t, forMode: .modalPanel)
                view.debugOpenAddImagePanel()
            }
            return
        }
        if env["SHOTPARK_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startCapture() }
            // Poll until the overlay is up (capture + windows can take a moment), then run.
            var tries = 0
            func attempt() {
                tries += 1
                guard let view = self.session?.primaryView, view.window?.isVisible == true else {
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { attempt() }; return }
                    print("FAIL no capture view (permission?)"); exit(2)
                }
                let results = view.runSelfTest()
                results.forEach { print($0) }
                let failed = results.filter { $0.hasPrefix("FAIL") }.count
                print(failed == 0 ? "ALL PASS (\(results.count))" : "\(failed) FAILED")
                self.session?.cancel()
                exit(failed == 0 ? 0 : 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { attempt() }
            return
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
        let h = Settings.shortcut(.history)
        historyHotKey = nil
        let cap = Settings.hotKey
        if !(h.keyCode == cap.keyCode && h.carbonModifiers == cap.carbonModifiers) { // never shadow the capture hotkey
            historyHotKey = HotKey(id: 2, keyCode: h.keyCode, modifiers: h.carbonModifiers) {
                ClipboardHistoryWindowController.shared.toggle()
            }
        }
        historyItem?.keyEquivalent = h.keyEquivalent
        historyItem?.keyEquivalentModifierMask = h.nsModifiers

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
        // Appears only when GitHub has a newer release (checked once a day).
        updateItem = NSMenuItem(title: "", action: #selector(openReleases), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        captureItem = NSMenuItem(title: L("영역 캡처", "Capture Region"), action: #selector(captureAction), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        pinsItem = NSMenuItem(title: "", action: #selector(closePins), keyEquivalent: "")
        pinsItem.target = self
        pinsItem.isHidden = true
        menu.addItem(pinsItem)
        let history = NSMenuItem(title: L("클립보드 이미지", "Clipboard Images"), action: #selector(openClipboardHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        historyItem = history
        let h = Settings.shortcut(.history)
        history.keyEquivalent = h.keyEquivalent
        history.keyEquivalentModifierMask = h.nsModifiers
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("설정… (단축키 · 저장 폴더)", "Settings… (Hotkey · Save Folder)"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let welcome = NSMenuItem(title: L("시작 안내", "Getting Started"), action: #selector(openWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)

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

        let check = NSMenuItem(title: L("업데이트 확인…", "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let about = NSMenuItem(title: L("ShotPark 정보", "About ShotPark"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: L("ShotPark 종료", "Quit ShotPark"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// SHOTPARK_CLIPTEST=1 SHOTPARK_CLIPDIR=/tmp/x — exercises clipboard history in a scratch folder,
    /// restores the user's clipboard, leaves the window up for 5 s (prints its window number), then quits.
    private func runClipboardTest() {
        let pb = NSPasteboard.general
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        func restoreClipboard() {
            pb.clearContents()
            let items = savedItems.map { d -> NSPasteboardItem in let it = NSPasteboardItem(); d.forEach { it.setData($1, forType: $0) }; return it }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        var out: [String] = []
        func check(_ n: String, _ ok: Bool, _ d: String = "") { out.append((ok ? "PASS " : "FAIL ") + n + (d.isEmpty ? "" : "  [\(d)]")) }
        func make(_ c: NSColor, _ w: CGFloat, _ h: CGFloat, _ label: String) -> NSImage {
            NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                c.setFill(); r.fill()
                NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: h / 4), .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 12, y: h / 3))
                return true
            }
        }
        let h = ClipboardHistory.shared
        h.clear()
        h.start()
        let colors: [NSColor] = [.systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple]
        for (i, c) in colors.enumerated() {
            Exporter.copy(make(c, CGFloat(300 + i * 60), 180, "Sample \(i + 1)"))
            h.poll()
        }
        check("records copied images", h.entries.count == colors.count, "\(h.entries.count)")
        let first = h.entries.first
        Exporter.copy(make(.systemPurple, 540, 180, "Sample 5")); h.poll()
        check("same image is not duplicated", h.entries.count == colors.count && h.entries.first?.hash == first?.hash)
        pb.clearContents()
        let secret = NSPasteboardItem()
        if let png = Exporter.pngData(make(.black, 100, 100, "x")) { secret.setData(png, forType: .png) }
        secret.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([secret]); h.poll()
        check("concealed items are skipped", h.entries.count == colors.count)
        pb.clearContents(); pb.setString("hello", forType: .string); h.poll()
        check("text is ignored", h.entries.count == colors.count)
        if let last = h.entries.last {
            h.copyToClipboard(last); h.poll()
            check("copy back moves to front, no duplicate", h.entries.first?.name == last.name && h.entries.count == colors.count)
        }
        h.stop()
        restoreClipboard()
        ClipboardHistoryWindowController.shared.show()
        check("window shows", ClipboardHistoryWindowController.shared.window?.isVisible == true)
        out.forEach { print($0) }
        print(out.contains { $0.hasPrefix("FAIL") } ? "SOME FAILED" : "ALL PASS (\(out.count))")
        print("WINDOW \(ClipboardHistoryWindowController.shared.window?.windowNumber ?? 0)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let v = ClipboardHistoryWindowController.shared.window?.contentView?.superview,
               let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/sp-clip-window.png"))
                print("RENDERED")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { h.clear(); exit(0) }
    }

    @objc private func closePins() { PinWindow.closeAll() }

    @objc private func openClipboardHistory() {
        ClipboardHistoryWindowController.shared.show()
    }

    @objc private func captureAction() {
        // Let the menu close first so it is not in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.startCapture() }
    }

    @objc private func openWelcome() { WelcomeWindowController.shared.show() }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func checkForUpdates() { UpdateChecker.shared.check(userInitiated: true) }
    @objc private func openReleases() { NSWorkspace.shared.open(UpdateChecker.releasesURL) }

    private func refreshUpdateItem() {
        if let v = UpdateChecker.shared.availableVersion {
            updateItem.title = L("⬆︎ ShotPark \(v) 업데이트 받기", "⬆︎ Update to ShotPark \(v)")
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
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
        가벼운 맥 네이티브 영역 캡처 도구 (Apple Silicon · Intel)

        \(Settings.hotKey.display)  영역 캡처 시작 (설정에서 변경 가능)
        드래그  영역 선택 · 핸들로 크기 조절 · 안쪽 드래그로 이동
        P 펜 · L 선 · A 화살표 · R 사각형 · E 타원 · M 마커 · T 텍스트 · N 번호 · S 이모지 도장 · V 선택
        Enter / ⌘C  클립보드로 복사   ⌘S  PNG 저장   ⌘⇧S  공유(Claude·Slack·카카오톡)
        ⌘Z  실행 취소   Esc  취소

        저장 폴더: \((Settings.saveFolder.path as NSString).abbreviatingWithTildeInPath)
        """ : """
        A lightweight native Mac region capture tool (Apple Silicon · Intel) — a Lightshot / PicPick alternative

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
        pinsItem.isHidden = PinWindow.count == 0
        pinsItem.title = L("고정한 캡처 모두 닫기 (\(PinWindow.count))", "Close All Pinned Captures (\(PinWindow.count))")
    }
}
