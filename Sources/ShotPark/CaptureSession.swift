import AppKit
import UniformTypeIdentifiers

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌘W (Window ▸ Close) while the overlay is up cancels the capture instead of beeping.
    var onPerformClose: (() -> Void)?
    override func performClose(_ sender: Any?) { onPerformClose?() }
}

/// One capture session = one overlay window per screen, until the user copies/saves/cancels.
final class CaptureSession {
    enum Mode { case copy, save, shareApp(ShareTarget) }

    private var windows: [OverlayWindow] = []
    private var views: [CaptureView] = []
    private let onEnd: () -> Void
    private var ended = false
    private var keyMonitor: Any?

    init(onEnd: @escaping () -> Void) {
        self.onEnd = onEnd
    }

    @MainActor
    func start() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let captured = await ScreenCapture.captureAll(NSScreen.screens)
        NSLog("ShotPark: captured \(captured.count) display(s) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
        guard !captured.isEmpty else {
            end()
            showPermissionAlert()
            return
        }

        let windowFrames = ScreenCapture.onScreenWindowFrames()
        for (screen, img) in captured {
            let win = OverlayWindow(screen: screen)
            win.onPerformClose = { [weak self] in self?.cancel() }
            let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            container.wantsLayer = true
            container.layer?.contents = img
            container.layer?.contentsGravity = .resize
            container.layer?.magnificationFilter = .linear

            let view = CaptureView(frame: container.bounds, screenshot: img)
            view.autoresizingMask = [.width, .height]
            view.session = self
            view.windowFrames = windowFrames.map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
            container.addSubview(view)

            win.contentView = container
            windows.append(win)
            views.append(view)
        }

        // ⌘C / Enter work no matter which overlay window or view currently has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.ended else { return event }
            if let fr = event.window?.firstResponder, fr is NSTextView { return event } // typing a text annotation
            // Key codes, not characters: with a Korean input source ⌘C reports "ㅊ", not "c".
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let view = self.views.first(where: { $0.state == .selected }) {
                if flags == .command && event.keyCode == 8 /* C */ { view.copyToClipboard(); return nil }
                if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) { view.copyToClipboard(); return nil }
            }
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
        for (i, win) in windows.enumerated() {
            if i == 0 { win.makeKeyAndOrderFront(nil) } else { win.orderFront(nil) }
        }
        // make the view under the mouse the first responder
        let mouse = NSEvent.mouseLocation
        if let win = windows.first(where: { $0.frame.contains(mouse) }), let view = win.contentView?.subviews.first {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
        } else if let win = windows.first, let view = win.contentView?.subviews.first {
            win.makeFirstResponder(view)
        }
        views.forEach { $0.refreshHover() }
    }

    var primaryView: CaptureView? { views.first }

    func activate(_ view: CaptureView) {
        for v in views where v !== view { v.reset() }
        if let win = view.window, !win.isKeyWindow {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
        }
    }

    func cancel() {
        end()
    }

    func finish(with image: NSImage, mode: Mode) {
        end()
        switch mode {
        case .copy:
            Exporter.copy(image)
            if Settings.copyAlsoSaves, let url = Exporter.saveDirect(image) {
                Toast.show("클립보드에 복사됨 · 저장됨", subtitle: url.lastPathComponent, duration: 1.6,
                           onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            } else {
                Toast.show("클립보드에 복사됨", duration: 1.1)
            }
        case .save:
            Exporter.save(image)
        case .shareApp(let target):
            Exporter.share(image, to: target)
        }
    }

    /// System share sheet (Mail, Messages, AirDrop, Notes, and any app with a share extension).
    /// The overlay stays up until the service finishes so sheets have a window to attach to.
    private var sharingDelegate: SharingDelegate?
    func showSystemShareSheet(for image: NSImage, relativeTo rect: NSRect, of view: NSView) {
        guard let url = Exporter.writeTempPNG(image) else { return }
        let picker = NSSharingServicePicker(items: [url])
        let delegate = SharingDelegate(onDone: { [weak self] in self?.end() })
        sharingDelegate = delegate
        picker.delegate = delegate
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private final class SharingDelegate: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor service: NSSharingService) -> NSSharingServiceDelegate? { self }
        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { onDone() }
        func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) { onDone() }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for w in windows {
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        windows = []
        views = []
        onEnd()
        ScreenCapture.prewarm() // keep the next capture instant
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "화면 기록 권한이 필요합니다"
        alert.informativeText = "시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 ShotPark을 허용한 뒤 다시 시도해 주세요."
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapture.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Apps we can hand a screenshot to directly.
struct ShareTarget {
    let name: String
    let bundleIDs: [String]
    let symbol: String

    static let all: [ShareTarget] = [
        ShareTarget(name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"], symbol: "sparkles"),
        ShareTarget(name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"], symbol: "number"),
        ShareTarget(name: "카카오톡", bundleIDs: ["com.kakao.KakaoTalkMac"], symbol: "bubble.left.fill"),
    ]

    var appURL: URL? {
        for id in bundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return u }
        }
        let fallback = URL(fileURLWithPath: "/Applications/\(name == "카카오톡" ? "KakaoTalk" : name).app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    var isInstalled: Bool { appURL != nil }

    /// Installed targets only.
    static var installed: [ShareTarget] { all.filter { $0.isInstalled } }
}

enum Exporter {
    static func writeTempPNG(_ image: NSImage) -> URL? {
        guard let data = pngData(image) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShotPark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Settings.fileName())
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    /// Copies the image to the clipboard, then opens it with the target app so
    /// it lands in the app's upload / attach flow. If the app refuses the file,
    /// it is still activated and the image is ready to paste with ⌘V.
    static func share(_ image: NSImage, to target: ShareTarget) {
        copy(image)
        guard let appURL = target.appURL else { return }
        let fileURL = writeTempPNG(image)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let fileURL {
            NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: config) { _, error in
                if error != nil {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                }
            }
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = pngData(image) {
            pb.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    /// Writes straight into the configured folder with a unique name. Silent; returns the URL.
    @discardableResult
    static func saveDirect(_ image: NSImage) -> URL? {
        guard let data = pngData(image) else { return nil }
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: Settings.fileName())
        do { try data.write(to: url, options: .atomic); return url } catch {
            NSLog("Direct save failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(_ image: NSImage) {
        guard let data = pngData(image) else { return }
        let folder = Settings.saveFolder
        if Settings.saveAlsoCopies { copy(image) }

        if Settings.saveDirectly {
            if let url = saveDirect(image) {
                Toast.show(Settings.saveAlsoCopies ? "저장됨 · 클립보드에 복사됨 — \(url.lastPathComponent)" : "저장됨 — \(url.lastPathComponent)",
                           subtitle: (folder.path as NSString).abbreviatingWithTildeInPath + "  ·  클릭하면 Finder에서 열림",
                           onClick: { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                return
            }
            NSLog("falling back to save panel")
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Settings.fileName()
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        var n = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}
