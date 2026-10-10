import AppKit
import Carbon

// MARK: - Persisted settings

extension Notification.Name {
    static let settingsChanged = Notification.Name("ShotPark.settingsChanged")
}

struct HotKeySpec: Equatable {
    var keyCode: UInt32          // Carbon virtual key code
    var carbonModifiers: UInt32  // cmdKey | shiftKey | optionKey | controlKey
    var display: String          // e.g. "⌘⇧9"

    static let `default` = HotKeySpec(keyCode: UInt32(kVK_ANSI_9),
                                      carbonModifiers: UInt32(cmdKey | shiftKey),
                                      display: "⌘⇧9")

    var nsModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        return f
    }

    /// Key equivalent string for NSMenuItem (lowercase character, or "" if none).
    var keyEquivalent: String {
        let last = display.last.map(String.init) ?? ""
        return last.count == 1 && last.unicodeScalars.first!.isASCII ? last.lowercased() : ""
    }

    static func from(event: NSEvent) -> HotKeySpec? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = UInt32(event.keyCode)
        let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let isFunctionKey = functionKeys.contains(Int(event.keyCode))
        guard !flags.isEmpty || isFunctionKey else { return nil }
        if event.keyCode == 53 { return nil } // esc

        var carbon: UInt32 = 0
        var text = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); text += "⌘" }
        text += keyName(for: event)
        return HotKeySpec(keyCode: code, carbonModifiers: carbon, display: text)
    }

    private static func keyName(for event: NSEvent) -> String {
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let s = special[Int(event.keyCode)] { return s }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

enum Settings {
    private static let d = UserDefaults.standard
    private enum K {
        static let keyCode = "hotKeyCode"
        static let mods = "hotKeyModifiers"
        static let display = "hotKeyDisplay"
        static let folder = "saveFolderPath"
        static let direct = "saveDirectly"
    }

    static var hotKey: HotKeySpec {
        get {
            guard d.object(forKey: K.keyCode) != nil else { return .default }
            return HotKeySpec(keyCode: UInt32(d.integer(forKey: K.keyCode)),
                              carbonModifiers: UInt32(d.integer(forKey: K.mods)),
                              display: d.string(forKey: K.display) ?? "?")
        }
        set {
            d.set(Int(newValue.keyCode), forKey: K.keyCode)
            d.set(Int(newValue.carbonModifiers), forKey: K.mods)
            d.set(newValue.display, forKey: K.display)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static var saveFolder: URL {
        get {
            if let p = d.string(forKey: K.folder) {
                let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return defaultFolder
        }
        set {
            d.set(newValue.path, forKey: K.folder)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// true → ⌘S writes straight into `saveFolder` without a dialog.
    static var saveDirectly: Bool {
        get { d.object(forKey: K.direct) == nil ? true : d.bool(forKey: K.direct) }
        set { d.set(newValue, forKey: K.direct); NotificationCenter.default.post(name: .settingsChanged, object: nil) }
    }

    static func fileName(date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(fmt.string(from: date)).png"
    }
}

// MARK: - Hotkey recorder control

final class HotKeyRecorderView: NSView {
    var spec: HotKeySpec = Settings.hotKey { didSet { needsDisplay = true } }
    var onChange: ((HotKeySpec) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 1.5 : 1
        path.stroke()

        let text = recording ? "키 조합을 누르세요…" : spec.display
        let attrs: [NSAttributedString.Key: Any] = [
            .font: recording ? NSFont.systemFont(ofSize: 12) : NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func becomeFirstResponder() -> Bool { recording = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; return true }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; window?.makeFirstResponder(nil); return }
        if let s = HotKeySpec.from(event: event) {
            spec = s
            recording = false
            window?.makeFirstResponder(nil)
            onChange?(s)
        } else {
            NSSound.beep()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Swallow ⌘-combos while recording so they become the hotkey instead of menu actions.
        guard recording, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) { needsDisplay = true }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let recorder = HotKeyRecorderView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let directCheckbox = NSButton(checkboxWithTitle: "⌘S 저장 시 확인 창 없이 지정 폴더에 바로 저장", target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 230),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ShotPark 설정"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // hotkey row
        recorder.onChange = { [weak self] spec in
            Settings.hotKey = spec
            self?.refresh()
        }
        let resetBtn = NSButton(title: "기본값(⌘⇧9)", target: self, action: #selector(resetHotKey))
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small
        let hotkeyRow = NSStackView(views: [recorder, resetBtn])
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .centerY
        recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let hotkeyHint = NSTextField(wrappingLabelWithString: "클릭한 뒤 원하는 키 조합을 누르세요. ⌘ / ⌥ / ⌃ 중 하나가 포함되거나 F키여야 합니다.")
        hotkeyHint.font = .systemFont(ofSize: 11)
        hotkeyHint.textColor = .secondaryLabelColor

        // folder row
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseBtn = NSButton(title: "변경…", target: self, action: #selector(chooseFolder))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.controlSize = .small
        let openBtn = NSButton(title: "Finder에서 열기", target: self, action: #selector(openFolder))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        let folderRow = NSStackView(views: [folderLabel, chooseBtn, openBtn])
        folderRow.spacing = 8
        folderRow.alignment = .centerY

        directCheckbox.target = self
        directCheckbox.action = #selector(toggleDirect)
        directCheckbox.font = .systemFont(ofSize: 12)

        let grid = NSGridView(views: [
            [label("캡처 단축키"), hotkeyRow],
            [NSGridCell.emptyContentView, hotkeyHint],
            [label("저장 폴더"), folderRow],
            [NSGridCell.emptyContentView, directCheckbox],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 90
        grid.column(at: 1).width = 340
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 2).yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)

        let footer = NSTextField(wrappingLabelWithString: "변경 사항은 즉시 적용됩니다.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.alignment = .right
        return l
    }

    private func refresh() {
        recorder.spec = Settings.hotKey
        let path = Settings.saveFolder.path
        folderLabel.stringValue = (path as NSString).abbreviatingWithTildeInPath
        folderLabel.toolTip = path
        directCheckbox.state = Settings.saveDirectly ? .on : .off
    }

    @objc private func resetHotKey() {
        Settings.hotKey = .default
        refresh()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Settings.saveFolder
        panel.prompt = "이 폴더 사용"
        panel.message = "스크린샷을 저장할 폴더를 선택하세요"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Settings.saveFolder = url
            self?.refresh()
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Settings.saveFolder])
    }

    @objc private func toggleDirect() {
        Settings.saveDirectly = directCheckbox.state == .on
    }
}

// MARK: - Toast (small HUD shown after a direct save)

final class Toast {
    private static var current: NSWindow?

    static func show(_ text: String, subtitle: String? = nil, duration: TimeInterval = 2.2, onClick: (() -> Void)? = nil) {
        current?.orderOut(nil)

        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        let views: [NSView]
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = NSColor.white.withAlphaComponent(0.75)
            sub.lineBreakMode = .byTruncatingMiddle
            sub.maximumNumberOfLines = 1
            sub.preferredMaxLayoutWidth = 320
            views = [title, sub]
        } else {
            views = [title]
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize

        let container = ToastView(frame: NSRect(origin: .zero, size: size))
        container.onClick = onClick
        stack.frame = container.bounds
        container.addSubview(stack)

        guard let screen = NSScreen.main else { return }
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.maxY - size.height - 12)
        let win = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = true
        win.ignoresMouseEvents = onClick == nil
        win.collectionBehavior = [.canJoinAllSpaces, .transient]
        win.contentView = container
        win.alphaValue = 0
        win.orderFrontRegardless()
        current = win

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            win.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard current === win else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                win.animator().alphaValue = 0
            }, completionHandler: {
                if current === win { current = nil }
                win.orderOut(nil)
            })
        }
    }

    private final class ToastView: NSView {
        var onClick: (() -> Void)?
        override func draw(_ dirtyRect: NSRect) {
            let p = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
            NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
            p.fill()
        }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}
