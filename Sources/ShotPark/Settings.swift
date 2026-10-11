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

    /// True when `event` is exactly this key + modifiers (used for in-capture shortcuts).
    func matches(_ event: NSEvent) -> Bool {
        UInt32(event.keyCode) == keyCode
            && event.modifierFlags.intersection([.command, .shift, .option, .control]) == nsModifiers
    }

    /// `allowPlain`: accept a bare key (or ⇧+key) — fine for shortcuts that only work inside a capture.
    static func from(event: NSEvent, allowPlain: Bool = false) -> HotKeySpec? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = UInt32(event.keyCode)
        let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let isFunctionKey = functionKeys.contains(Int(event.keyCode))
        guard allowPlain || !flags.subtracting(.shift).isEmpty || isFunctionKey else { return nil }
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
        // Base character without any modifier (so ⇧8 reads "8", not "*").
        if let base = event.characters(byApplyingModifiers: []), !base.isEmpty { return base.uppercased() }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    /// Re-derive a display string from the stored key code for the common keys, so entries saved by
    /// older builds (which could show "*" for ⇧8) are shown correctly.
    static func normalizedDisplay(keyCode: UInt32, carbonModifiers: UInt32, fallback: String) -> String {
        let keys: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        ]
        guard let name = keys[Int(keyCode)] else { return fallback }
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + name
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
        static let copyAlsoSaves = "copyAlsoSaves"
        static let saveAlsoCopies = "saveAlsoCopies"
    }

    /// ⌘C also writes a PNG into the save folder.
    static var copyAlsoSaves: Bool {
        get { d.bool(forKey: K.copyAlsoSaves) }
        set { d.set(newValue, forKey: K.copyAlsoSaves) }
    }

    /// ⌘S also puts the image on the clipboard.
    static var saveAlsoCopies: Bool {
        get { d.object(forKey: K.saveAlsoCopies) == nil ? true : d.bool(forKey: K.saveAlsoCopies) }
        set { d.set(newValue, forKey: K.saveAlsoCopies) }
    }

    static var hotKey: HotKeySpec {
        get {
            guard d.object(forKey: K.keyCode) != nil else { return .default }
            let code = UInt32(d.integer(forKey: K.keyCode)), mods = UInt32(d.integer(forKey: K.mods))
            return HotKeySpec(keyCode: code, carbonModifiers: mods,
                              display: HotKeySpec.normalizedDisplay(keyCode: code, carbonModifiers: mods,
                                                                    fallback: d.string(forKey: K.display) ?? "?"))
        }
        set {
            d.set(Int(newValue.keyCode), forKey: K.keyCode)
            d.set(Int(newValue.carbonModifiers), forKey: K.mods)
            d.set(newValue.display, forKey: K.display)
            NotificationCenter.default.post(name: .settingsChanged, object: nil)
        }
    }

    /// Configurable shortcuts besides the capture hotkey.
    enum Shortcut: String, CaseIterable {
        case history   // global: open Clipboard Images
        case mosaic    // in a capture: mosaic / blur tool
        case ocr       // in a capture: extract text

        var defaultSpec: HotKeySpec {
            switch self {
            // ⌃⌘V ("paste from history"): clear of the ⇧⌘-digit combos people use for capture.
            case .history: return HotKeySpec(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | controlKey), display: "⌃⌘V")
            case .mosaic:  return HotKeySpec(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: 0, display: "B")
            case .ocr:     return HotKeySpec(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey), display: "⇧⌘C")
            }
        }
        /// In-capture shortcuts may be a bare key; global ones need a modifier.
        var allowsPlainKey: Bool { self != .history }
    }

    static func shortcut(_ s: Shortcut) -> HotKeySpec {
        let k = "shortcut.\(s.rawValue)"
        guard d.object(forKey: k + ".code") != nil else { return s.defaultSpec }
        let code = UInt32(d.integer(forKey: k + ".code")), mods = UInt32(d.integer(forKey: k + ".mods"))
        return HotKeySpec(keyCode: code, carbonModifiers: mods,
                          display: HotKeySpec.normalizedDisplay(keyCode: code, carbonModifiers: mods, fallback: d.string(forKey: k + ".display") ?? "?"))
    }

    static func setShortcut(_ s: Shortcut, _ spec: HotKeySpec?) {
        let k = "shortcut.\(s.rawValue)"
        if let spec {
            d.set(Int(spec.keyCode), forKey: k + ".code")
            d.set(Int(spec.carbonModifiers), forKey: k + ".mods")
            d.set(spec.display, forKey: k + ".display")
        } else {
            [".code", ".mods", ".display"].forEach { d.removeObject(forKey: k + $0) }
        }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
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
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "shotpark-\(fmt.string(from: date)).png"
    }
}

// MARK: - Hotkey recorder control

final class HotKeyRecorderView: NSView {
    var spec: HotKeySpec = Settings.hotKey { didSet { needsDisplay = true } }
    var onChange: ((HotKeySpec) -> Void)?
    var allowsPlainKeys = false
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

        let text = recording ? L("키 조합을 누르세요…", "Press a key combination…") : spec.display
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

    override func becomeFirstResponder() -> Bool { true } // recording starts on click only
    override func resignFirstResponder() -> Bool { recording = false; return true }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; window?.makeFirstResponder(nil); return }
        if let s = HotKeySpec.from(event: event, allowPlain: allowsPlainKeys) {
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
    private let directCheckbox = NSButton(checkboxWithTitle: L("⌘S 저장 시 확인 창 없이 지정 폴더에 바로 저장", "⌘S saves straight to the folder, no dialog"), target: nil, action: nil)
    private let saveCopiesCheckbox = NSButton(checkboxWithTitle: L("⌘S 저장할 때 클립보드에도 복사", "⌘S also copies to the clipboard"), target: nil, action: nil)
    private let copySavesCheckbox = NSButton(checkboxWithTitle: L("⌘C 복사할 때 저장 폴더에도 PNG 저장", "⌘C also saves a PNG to the folder"), target: nil, action: nil)
    private var colorWells: [NSColorWell] = []
    private var shortcutRecorders: [Settings.Shortcut: HotKeyRecorderView] = [:]
    private let historyCheckbox = NSButton(checkboxWithTitle: L("복사한 이미지 기록 (최근 30개)", "Keep copied images (last 30)"), target: nil, action: nil)

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: L10n.isKorean ? 500 : 540, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("ShotPark 설정", "ShotPark Settings")
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
        let resetBtn = NSButton(title: L("기본값(⌘⇧9)", "Default (⌘⇧9)"), target: self, action: #selector(resetHotKey))
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small
        let hotkeyRow = NSStackView(views: [recorder, resetBtn])
        hotkeyRow.spacing = 8
        hotkeyRow.alignment = .centerY
        recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let hotkeyHint = NSTextField(wrappingLabelWithString: L("클릭한 뒤 원하는 키 조합을 누르세요. ⌘ / ⌥ / ⌃ 중 하나가 포함되거나 F키여야 합니다.", "Click, then press the combination you want. It must include ⌘ / ⌥ / ⌃ or be an F key."))
        hotkeyHint.font = .systemFont(ofSize: 11)
        hotkeyHint.textColor = .secondaryLabelColor

        // folder row
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseBtn = NSButton(title: L("변경…", "Change…"), target: self, action: #selector(chooseFolder))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.controlSize = .small
        let openBtn = NSButton(title: L("Finder에서 열기", "Show in Finder"), target: self, action: #selector(openFolder))
        openBtn.bezelStyle = .rounded
        openBtn.controlSize = .small
        let folderRow = NSStackView(views: [folderLabel, chooseBtn, openBtn])
        folderRow.spacing = 8
        folderRow.alignment = .centerY

        directCheckbox.target = self
        directCheckbox.action = #selector(toggleDirect)
        directCheckbox.font = .systemFont(ofSize: 12)
        saveCopiesCheckbox.target = self
        saveCopiesCheckbox.action = #selector(toggleSaveCopies)
        saveCopiesCheckbox.font = .systemFont(ofSize: 12)
        copySavesCheckbox.target = self
        copySavesCheckbox.action = #selector(toggleCopySaves)
        copySavesCheckbox.font = .systemFont(ofSize: 12)

        // annotation palette row: 10 colour wells + reset
        colorWells = (0..<ColorPaletteView.defaultColors.count).map { i in
            let well: NSColorWell
            if #available(macOS 13.0, *) { well = NSColorWell(style: .minimal) } else { well = NSColorWell() }
            well.tag = i
            well.target = self
            well.action = #selector(paletteChanged(_:))
            well.isBordered = true
            well.widthAnchor.constraint(equalToConstant: 26).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            well.toolTip = L("클릭해서 색 바꾸기", "Click to change this colour")
            return well
        }
        let paletteStack = NSStackView(views: colorWells)
        paletteStack.spacing = 3
        let paletteReset = NSButton(title: L("기본값", "Default"), target: self, action: #selector(resetPalette))
        paletteReset.bezelStyle = .rounded
        paletteReset.controlSize = .small
        let paletteRow = NSStackView(views: [paletteStack, paletteReset])
        paletteRow.spacing = 10
        let paletteHint = NSTextField(wrappingLabelWithString: L("캡처 화면의 색상 팔레트에 보이는 10가지 색입니다. 클릭해서 원하는 색으로 바꾸면 바로 저장됩니다.", "The 10 colours shown in the capture palette. Click one to change it; it's saved immediately."))
        paletteHint.font = .systemFont(ofSize: 11)
        paletteHint.textColor = .secondaryLabelColor
        paletteHint.preferredMaxLayoutWidth = L10n.isKorean ? 330 : 340

        historyCheckbox.target = self
        historyCheckbox.action = #selector(toggleHistory)
        historyCheckbox.font = .systemFont(ofSize: 12)
        let historyClear = NSButton(title: L("기록 지우기", "Clear"), target: self, action: #selector(clearHistory))
        historyClear.bezelStyle = .rounded
        historyClear.controlSize = .small
        let historyRow = NSStackView(views: [historyCheckbox, historyClear])
        historyRow.spacing = 8
        historyRow.alignment = .centerY
        let historyHint = NSTextField(wrappingLabelWithString: L("다른 앱에서 복사한 이미지도 포함되며, 내 맥에만 저장됩니다. 비밀번호 관리자처럼 숨김 표시된 항목은 기록하지 않습니다.", "Includes images copied in other apps; stored only on this Mac. Items marked as concealed (e.g. by password managers) are skipped."))
        historyHint.font = .systemFont(ofSize: 11)
        historyHint.textColor = .secondaryLabelColor
        historyHint.preferredMaxLayoutWidth = L10n.isKorean ? 330 : 340

        // other shortcuts: clipboard images (global), mosaic + text extraction (inside a capture)
        func shortcutRow(_ s: Settings.Shortcut, note: String) -> NSView {
            let rec = HotKeyRecorderView()
            rec.allowsPlainKeys = s.allowsPlainKey
            rec.spec = Settings.shortcut(s)
            rec.onChange = { [weak self] spec in
                if s == .history && spec.keyCode == Settings.hotKey.keyCode && spec.carbonModifiers == Settings.hotKey.carbonModifiers {
                    NSSound.beep(); self?.refresh(); return   // same as the capture hotkey
                }
                Settings.setShortcut(s, spec); self?.refresh()
            }
            rec.widthAnchor.constraint(equalToConstant: 120).isActive = true
            rec.heightAnchor.constraint(equalToConstant: 24).isActive = true
            shortcutRecorders[s] = rec
            let reset = NSButton(title: L("기본값", "Default"), target: self, action: #selector(resetShortcut(_:)))
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.tag = Settings.Shortcut.allCases.firstIndex(of: s) ?? 0
            let n = NSTextField(labelWithString: note)
            n.font = .systemFont(ofSize: 11)
            n.textColor = .secondaryLabelColor
            let row = NSStackView(views: [rec, reset, n])
            row.spacing = 8
            row.alignment = .centerY
            return row
        }
        let historyKeyRow = shortcutRow(.history, note: L("어디서나", "anywhere"))
        let mosaicKeyRow = shortcutRow(.mosaic, note: L("캡처 중", "during a capture"))
        let ocrKeyRow = shortcutRow(.ocr, note: L("캡처 중", "during a capture"))

        let grid = NSGridView(views: [
            [label(L("캡처 단축키", "Capture hotkey")), hotkeyRow],
            [NSGridCell.emptyContentView, hotkeyHint],
            [label(L("클립보드 이미지", "Clipboard images")), historyKeyRow],
            [label(L("모자이크", "Mosaic / blur")), mosaicKeyRow],
            [label(L("텍스트 추출", "Extract text")), ocrKeyRow],
            [label(L("저장 폴더", "Save folder")), folderRow],
            [NSGridCell.emptyContentView, directCheckbox],
            [NSGridCell.emptyContentView, saveCopiesCheckbox],
            [NSGridCell.emptyContentView, copySavesCheckbox],
            [label(L("주석 색상", "Palette")), paletteRow],
            [NSGridCell.emptyContentView, paletteHint],
            [label(L("클립보드", "Clipboard")), historyRow],
            [NSGridCell.emptyContentView, historyHint],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = L10n.isKorean ? 100 : 120
        grid.column(at: 1).width = L10n.isKorean ? 340 : 350
        grid.rowAlignment = .firstBaseline
        for r in [0, 2, 3, 4, 5, 9, 11] { grid.row(at: r).yPlacement = .center }
        grid.row(at: 5).topPadding = 6   // save folder
        grid.row(at: 9).topPadding = 6   // palette
        grid.row(at: 11).topPadding = 6  // clipboard
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)

        let footer = NSTextField(wrappingLabelWithString: L("변경 사항은 즉시 적용됩니다.", "Changes apply immediately."))
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
        saveCopiesCheckbox.state = Settings.saveAlsoCopies ? .on : .off
        copySavesCheckbox.state = Settings.copyAlsoSaves ? .on : .off
        historyCheckbox.state = ClipboardHistory.isEnabled ? .on : .off
        for (s, rec) in shortcutRecorders { rec.spec = Settings.shortcut(s) }
        let palette = Preferences.palette
        for (i, well) in colorWells.enumerated() where i < palette.count { well.color = palette[i] }
    }

    @objc private func paletteChanged(_ sender: NSColorWell) {
        var palette = Preferences.palette
        guard sender.tag < palette.count else { return }
        palette[sender.tag] = sender.color.usingColorSpace(.sRGB) ?? sender.color
        Preferences.palette = palette
    }

    @objc private func resetPalette() {
        Preferences.resetPalette()
        NSColorPanel.shared.close()
        refresh()
    }

    @objc private func toggleSaveCopies() { Settings.saveAlsoCopies = saveCopiesCheckbox.state == .on }
    @objc private func toggleCopySaves() { Settings.copyAlsoSaves = copySavesCheckbox.state == .on }
    @objc private func toggleHistory() { ClipboardHistory.isEnabled = historyCheckbox.state == .on }
    @objc private func clearHistory() {
        ClipboardHistory.shared.clear()
        Toast.show(L("클립보드 이미지 기록을 지웠습니다", "Clipboard image history cleared"), duration: 1.4)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let s = Settings.Shortcut.allCases[sender.tag]
        Settings.setShortcut(s, nil)
        refresh()
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
        panel.prompt = L("이 폴더 사용", "Use This Folder")
        panel.message = L("스크린샷을 저장할 폴더를 선택하세요", "Choose where screenshots are saved")
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
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) // visible over the capture overlay too
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
