import AppKit

/// "Clipboard images" window: a grid of recently copied images.
/// Click (or ↩) copies one back to the clipboard and closes; drag one into another app;
/// right-click for Save / Show in Finder / Delete.
final class ClipboardHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClipboardHistoryWindowController()

    private let grid = ClipboardGridView()
    private let scroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let clearButton = NSButton(title: L("모두 지우기", "Clear All"), target: nil, action: nil)

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = L("클립보드 이미지", "Clipboard Images")
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.minSize = NSSize(width: 420, height: 300)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        NotificationCenter.default.addObserver(forName: .clipboardHistoryChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func toggle() {
        if window?.isVisible == true && window?.isKeyWindow == true { close(); return }
        show()
    }

    func show() {
        ClipboardHistory.shared.poll()
        reload()
        grid.selected = ClipboardHistory.shared.entries.isEmpty ? nil : 0
        // Centre on the screen with the mouse.
        if let win = window {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                win.setFrameOrigin(NSPoint(x: vf.midX - win.frame.width / 2, y: vf.midY - win.frame.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(grid)
        window?.contentView?.layoutSubtreeIfNeeded()
        relayout()
        scroll.contentView.scroll(to: .zero)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bg)

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: L("클릭·↩ 복사  ·  드래그로 다른 앱에 넣기  ·  ⌫ 삭제  ·  우클릭 더보기",
                                                  "Click / ↩ to copy  ·  drag into another app  ·  ⌫ delete  ·  right-click for more"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.target = self
        clearButton.action = #selector(clearAll)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        let header = NSStackView(views: [countLabel, hint, NSView(), clearButton])
        header.spacing = 12
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: content.topAnchor), bg.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bg.leadingAnchor.constraint(equalTo: content.leadingAnchor), bg.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])

        grid.onCopy = { [weak self] e in
            ClipboardHistory.shared.copyToClipboard(e)
            self?.close()
            Toast.show(L("클립보드에 복사됨", "Copied to clipboard"), subtitle: L("⌘V로 붙여넣기", "Paste with ⌘V"), duration: 1.4)
        }
        grid.onClose = { [weak self] in self?.close() }
        grid.onSave = { [weak self] e in self?.save(e) }
    }

    private func reload() {
        let h = ClipboardHistory.shared
        grid.entries = h.entries
        countLabel.stringValue = L("\(h.entries.count)개 / 최근 \(ClipboardHistory.maxCount)개 보관", "\(h.entries.count) of last \(ClipboardHistory.maxCount)")
        clearButton.isEnabled = !h.entries.isEmpty
        emptyLabel.isHidden = !h.entries.isEmpty
        emptyLabel.stringValue = ClipboardHistory.isEnabled
            ? L("아직 복사한 이미지가 없습니다.\n이미지를 ⌘C 하거나 ShotPark으로 캡처하면 여기에 쌓입니다.",
                "No copied images yet.\nImages you copy (⌘C) or capture with ShotPark will show up here.")
            : L("클립보드 이미지 기록이 꺼져 있습니다.\n설정에서 켤 수 있습니다.", "Clipboard image history is off.\nTurn it on in Settings.")
        relayout()
    }

    private func relayout() {
        let w = scroll.contentSize.width
        if w > 50 { grid.layoutForWidth(w) }
        else { DispatchQueue.main.async { [weak self] in self.map { $0.grid.layoutForWidth($0.scroll.contentSize.width) } } }
    }

    func windowDidResize(_ notification: Notification) { relayout() }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = L("클립보드 이미지 기록을 모두 지울까요?", "Clear all clipboard images?")
        alert.informativeText = L("ShotPark이 보관한 사본만 지워집니다. 지금 클립보드에 있는 내용은 그대로입니다.",
                                  "Only ShotPark's saved copies are removed; what's on the clipboard now stays.")
        alert.addButton(withTitle: L("모두 지우기", "Clear All"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard let win = window else { return }
        alert.beginSheetModal(for: win) { resp in
            if resp == .alertFirstButtonReturn { ClipboardHistory.shared.clear() }
        }
    }

    private func save(_ e: ClipboardHistory.Entry) {
        guard let win = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = Settings.saveFolder
        panel.nameFieldStringValue = Settings.fileName()
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let dest = panel.url else { return }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: ClipboardHistory.shared.url(e), to: dest)
        }
    }
}

final class ClipboardGridView: NSView, NSDraggingSource {
    var entries: [ClipboardHistory.Entry] = [] { didSet { if let s = selected, s >= entries.count { selected = entries.isEmpty ? nil : entries.count - 1 }; needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true; if let s = selected { scrollToVisible(cellRect(s).insetBy(dx: 0, dy: -8)) } } }
    var onCopy: ((ClipboardHistory.Entry) -> Void)?
    var onClose: (() -> Void)?
    var onSave: ((ClipboardHistory.Entry) -> Void)?

    private let cellW: CGFloat = 172, cellH: CGFloat = 150, gap: CGFloat = 10, inset: CGFloat = 8
    private var columns = 4
    private var hover: Int?
    private var mouseDownPoint: NSPoint?
    private var mouseDownIndex: Int?
    private let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func layoutForWidth(_ width: CGFloat) {
        columns = max(1, Int((width - inset * 2 + gap) / (cellW + gap)))
        let rows = (entries.count + columns - 1) / columns
        let h = max(inset * 2 + CGFloat(rows) * (cellH + gap), superview?.bounds.height ?? 0)
        setFrameSize(NSSize(width: width, height: h))
        needsDisplay = true
    }

    private func cellRect(_ i: Int) -> NSRect {
        let width = bounds.width - inset * 2
        let used = CGFloat(columns) * cellW + CGFloat(columns - 1) * gap
        let x0 = inset + max(0, (width - used) / 2)
        let r = i / columns, c = i % columns
        return NSRect(x: x0 + CGFloat(c) * (cellW + gap), y: inset + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
    }

    private func index(at p: NSPoint) -> Int? { entries.indices.first { cellRect($0).contains(p) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        for (i, e) in entries.enumerated() {
            let r = cellRect(i)
            guard r.intersects(dirtyRect) else { continue }
            let isSel = selected == i, isHover = hover == i
            let bg = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            (isSel ? NSColor.controlAccentColor.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(isHover ? 0.10 : 0.05)).setFill()
            bg.fill()
            if isSel {
                NSColor.controlAccentColor.setStroke(); bg.lineWidth = 2; bg.stroke()
            }
            let box = NSRect(x: r.minX + 8, y: r.minY + 8, width: r.width - 16, height: r.height - 34)
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            if let t = ClipboardHistory.shared.thumbnail(e) {
                let s = min(box.width / t.size.width, box.height / t.size.height, 1)
                let w = t.size.width * s, h = t.size.height * s
                t.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            let age = Date().timeIntervalSince(e.date)
            let when = age < 60 ? L("방금", "just now") : relFormatter.localizedString(for: e.date, relativeTo: Date())
            let text = "\(when)  ·  \(Int(e.pixelSize.width))×\(Int(e.pixelSize.height))"
            let str = NSAttributedString(string: text, attributes: caption)
            str.draw(in: NSRect(x: r.minX + 10, y: r.maxY - 22, width: r.width - 20, height: 16))
        }
    }

    // MARK: mouse

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        mouseDownIndex = index(at: p)
        if let i = mouseDownIndex { selected = i }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let i = mouseDownIndex, i < entries.count else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let e = entries[i]
        let url = ClipboardHistory.shared.url(e) as NSURL
        let item = NSDraggingItem(pasteboardWriter: url)
        let thumb = ClipboardHistory.shared.thumbnail(e) ?? NSImage()
        let s = min(120 / max(thumb.size.width, 1), 120 / max(thumb.size.height, 1), 1)
        let size = NSSize(width: thumb.size.width * s, height: thumb.size.height * s)
        item.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; mouseDownIndex = nil }
        guard mouseDownPoint != nil, let i = mouseDownIndex, i < entries.count,
              index(at: convert(event.locationInWindow, from: nil)) == i else { return }
        onCopy?(entries[i])
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        selected = i
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.target = self; it.tag = i; menu.addItem(it)
        }
        add(L("복사", "Copy"), #selector(menuCopy(_:)))
        add(L("다른 이름으로 저장…", "Save As…"), #selector(menuSave(_:)))
        add(L("Finder에서 보기", "Show in Finder"), #selector(menuReveal(_:)))
        menu.addItem(.separator())
        add(L("기록에서 삭제", "Remove from History"), #selector(menuDelete(_:)))
        return menu
    }
    @objc private func menuCopy(_ s: NSMenuItem) { if s.tag < entries.count { onCopy?(entries[s.tag]) } }
    @objc private func menuSave(_ s: NSMenuItem) { if s.tag < entries.count { onSave?(entries[s.tag]) } }
    @objc private func menuReveal(_ s: NSMenuItem) {
        if s.tag < entries.count { NSWorkspace.shared.activateFileViewerSelecting([ClipboardHistory.shared.url(entries[s.tag])]) }
    }
    @objc private func menuDelete(_ s: NSMenuItem) { if s.tag < entries.count { ClipboardHistory.shared.remove(entries[s.tag]) } }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        let n = entries.count
        switch Int(event.keyCode) {
        case 53: onClose?()                                                     // esc
        case 36, 76: if let s = selected, s < n { onCopy?(entries[s]) }         // return
        case 51, 117: if let s = selected, s < n { ClipboardHistory.shared.remove(entries[s]) } // delete
        case 123: if n > 0 { selected = max(0, (selected ?? 0) - 1) }
        case 124: if n > 0 { selected = min(n - 1, (selected ?? -1) + 1) }
        case 125: if n > 0 { selected = min(n - 1, (selected ?? -columns) + columns) }
        case 126: if n > 0 { selected = max(0, (selected ?? 0) - columns) }
        default: super.keyDown(with: event)
        }
    }
}
