import AppKit

/// Full-screen overlay view: region selection, annotation canvas, toolbar host.
/// Coordinates are standard AppKit (origin bottom-left, points).
final class CaptureView: NSView, NSTextFieldDelegate {
    enum State { case idle, selecting, selected }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        case none
        case select(start: CGPoint)
        case move(startRect: CGRect, start: CGPoint)
        case resize(Handle, startRect: CGRect)
        case draw
        case moveShape(Int, startPoints: [CGPoint], start: CGPoint)
    }

    weak var session: CaptureSession?

    let screenshot: CGImage
    private(set) var state: State = .idle
    private(set) var selection: CGRect = .zero
    private var drag: Drag = .none

    private(set) var shapes: [Shape] = []
    private var currentShape: Shape?
    private var redoStack: [Shape] = []
    /// Index of the annotation highlighted for move / delete (selection tool).
    private var selectedShape: Int? { didSet { needsDisplay = true } }
    /// Window frames (view coords, front to back) for click-to-select-window.
    var windowFrames: [CGRect] = []
    private var hoverWindowRect: CGRect?

    var tool: Tool = .move {
        didSet {
            toolbar.selectedTool = tool
            if tool != .move { selectedShape = nil }
            layoutToolbar()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = Preferences.color {
        didSet { toolbar.currentColor = color; palette.selected = color; strokeOptions.color = color; Preferences.color = color; applyTextFieldStyle() }
    }
    var lineWidth: CGFloat = Preferences.lineWidth {
        didSet { strokeOptions.lineWidth = lineWidth; Preferences.lineWidth = lineWidth }
    }

    private let toolbar = ToolbarView()
    private let palette = ColorPaletteView()
    private let textOptions = TextOptionsView()
    private let strokeOptions = StrokeOptionsView()
    private var textField: NSTextField?

    var textSize: CGFloat = Preferences.textSize {
        didSet { textOptions.fontSize = textSize; Preferences.textSize = textSize; applyTextFieldStyle() }
    }
    var textStyle: TextStyles = Preferences.textStyle {
        didSet { textOptions.style = textStyle; Preferences.textStyle = textStyle; applyTextFieldStyle() }
    }
    var boxColor: NSColor = Preferences.boxColor {
        didSet { textOptions.boxColor = boxColor; Preferences.boxColor = boxColor; applyTextFieldStyle() }
    }
    var boxAlpha: CGFloat = Preferences.boxAlpha {
        didSet { textOptions.boxAlpha = boxAlpha; Preferences.boxAlpha = boxAlpha; applyTextFieldStyle() }
    }

    private var pixelScale: CGFloat { CGFloat(screenshot.width) / max(bounds.width, 1) }

    // MARK: init

    init(frame: NSRect, screenshot: CGImage) {
        self.screenshot = screenshot
        super.init(frame: frame)
        wantsLayer = true

        toolbar.isHidden = true
        toolbar.selectedTool = tool
        toolbar.currentColor = color
        toolbar.onAction = { [weak self] in self?.handle($0) }
        addSubview(toolbar)

        palette.isHidden = true
        palette.selected = color
        palette.onPick = { [weak self] c in
            guard let self else { return }
            self.color = c
            self.palette.isHidden = true
            if self.tool == .move { self.tool = .pen }
        }
        addSubview(palette)

        textOptions.isHidden = true
        textOptions.fontSize = textSize
        textOptions.style = textStyle
        textOptions.boxColor = boxColor
        textOptions.boxAlpha = boxAlpha
        textOptions.onSize = { [weak self] in self?.textSize = $0 }
        textOptions.onStyle = { [weak self] in self?.textStyle = $0 }
        textOptions.onBoxColor = { [weak self] in self?.boxColor = $0 }
        textOptions.onBoxAlpha = { [weak self] in self?.boxAlpha = $0 }
        textOptions.onResize = { [weak self] in self?.layoutToolbar() }
        addSubview(textOptions)

        strokeOptions.isHidden = true
        strokeOptions.lineWidth = lineWidth
        strokeOptions.color = color
        strokeOptions.onChange = { [weak self] in self?.lineWidth = $0 }
        addSubview(strokeOptions)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate], owner: self, userInfo: nil))
    }

    // MARK: public control

    func reset() {
        commitText()
        state = .idle
        selection = .zero
        shapes = []
        redoStack = []
        selectedShape = nil
        hoverWindowRect = nil
        currentShape = nil
        drag = .none
        toolbar.isHidden = true
        palette.isHidden = true
        textOptions.isHidden = true
        strokeOptions.isHidden = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: cursor

    override func resetCursorRects() {
        if state == .selected {
            addCursorRect(bounds, cursor: tool == .move ? .arrow : .crosshair)
            if tool == .move {
                addCursorRect(selection, cursor: .openHand)
                for (h, r) in handleRects() {
                    addCursorRect(r, cursor: cursor(for: h))
                }
            } else if tool == .text {
                addCursorRect(selection, cursor: .iBeam)
            }
            if tool == .move || tool == .text {
                for r in textShapeRects() { addCursorRect(r.intersection(selection), cursor: .openHand) }
            }
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private func cursor(for h: Handle) -> NSCursor {
        switch h {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        default: return .crosshair
        }
    }

    // MARK: geometry helpers

    private func handleRects() -> [(Handle, CGRect)] {
        guard state == .selected else { return [] }
        let s: CGFloat = 8
        let r = selection
        func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s) }
        return [
            (.topLeft, rect(r.minX, r.maxY)), (.top, rect(r.midX, r.maxY)), (.topRight, rect(r.maxX, r.maxY)),
            (.right, rect(r.maxX, r.midY)), (.bottomRight, rect(r.maxX, r.minY)), (.bottom, rect(r.midX, r.minY)),
            (.bottomLeft, rect(r.minX, r.minY)), (.left, rect(r.minX, r.midY)),
        ]
    }

    /// Index of the topmost annotation under `p`. Selection tool grabs any shape, text tool only text.
    private func shapeIndex(at p: CGPoint) -> Int? {
        for (i, sh) in shapes.enumerated().reversed() {
            if tool == .text && sh.tool != .text { continue }
            if sh.hitTest(p) { return i }
        }
        return nil
    }

    private func textShapeRects() -> [CGRect] {
        shapes.compactMap { sh in
            guard sh.tool == .text, let o = sh.points.first else { return nil }
            return Shape.boxRect(text: sh.text, fontSize: sh.fontSize, style: sh.textStyle, origin: o)
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(bounds)
    }

    private func layoutToolbar() {
        guard state == .selected else { toolbar.isHidden = true; palette.isHidden = true; textOptions.isHidden = true; strokeOptions.isHidden = true; return }
        let size = toolbar.intrinsicContentSize
        let gap: CGFloat = 8
        var x = selection.minX
        x = min(x, bounds.width - size.width - 4)
        x = max(x, 4)

        var y: CGFloat
        if selection.minY - gap - size.height >= 0 {
            y = selection.minY - gap - size.height            // below
        } else if selection.maxY + gap + size.height <= bounds.height {
            y = selection.maxY + gap                          // above
        } else {
            y = selection.minY + gap                          // inside
        }
        toolbar.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        toolbar.isHidden = false

        // secondary bars stack under (or above) the toolbar: text options (when text tool), then palette
        let below = toolbar.frame.minY - 6 - max(palette.frame.height, textOptions.frame.height) >= 0
        var nextY = below ? toolbar.frame.minY - 6 : toolbar.frame.maxY + 6
        func place(_ v: NSView) {
            let w = v.frame.width, h = v.frame.height
            let y = below ? nextY - h : nextY
            v.frame = NSRect(x: min(toolbar.frame.minX, bounds.width - w - 4), y: y, width: w, height: h)
            nextY = below ? y - 6 : y + h + 6
        }
        textOptions.isHidden = tool != .text
        if tool == .text { place(textOptions) }
        let drawing: Set<Tool> = [.pen, .line, .arrow, .rect, .ellipse, .marker]
        strokeOptions.isHidden = !drawing.contains(tool)
        if drawing.contains(tool) { place(strokeOptions) }
        place(palette)
    }

    // MARK: toolbar actions

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .selectTool(let t):
            commitText()
            palette.isHidden = true
            tool = (tool == t) ? .move : t
        case .color:
            palette.isHidden.toggle()
        case .undo:
            undoLast()
        case .copy:
            copyToClipboard()
        case .save:
            saveToFile()
        case .share:
            showShareMenu()
        case .close:
            session?.cancel()
        }
    }

    // MARK: share

    private func showShareMenu() {
        guard state == .selected else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for target in ShareTarget.installed {
            let item = NSMenuItem(title: "\(target.name)(으)로 보내기", action: #selector(shareToApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.name
            if let icon = target.appURL.map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            }
            menu.addItem(item)
        }
        if !ShareTarget.installed.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "다른 앱으로 공유… (메일 · 메시지 · AirDrop)", action: #selector(shareViaSystem), keyEquivalent: "")
        other.target = self
        menu.addItem(other)

        let anchor = toolbar.rect(for: .share) ?? toolbar.bounds
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 4), in: toolbar)
    }

    @objc private func shareToApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let target = ShareTarget.all.first(where: { $0.name == name }),
              let image = renderResult() else { return }
        session?.finish(with: image, mode: .shareApp(target))
    }

    @objc private func shareViaSystem() {
        guard let image = renderResult() else { return }
        let anchor = toolbar.rect(for: .share) ?? toolbar.bounds
        session?.showSystemShareSheet(for: image, relativeTo: anchor, of: toolbar)
    }

    /// Edit-menu actions (⌘Z / ⌘C) reach us here when a main menu exists; same behaviour as the key shortcuts.
    @objc func undo(_ sender: Any?) { undoLast() }
    @objc func copy(_ sender: Any?) { if state == .selected { copyToClipboard() } }

    func undoLast() {
        if textField != nil { cancelText(); return }
        if !shapes.isEmpty {
            redoStack.append(shapes.removeLast())
            selectedShape = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    func redoLast() {
        guard let sh = redoStack.popLast() else { return }
        shapes.append(sh)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        session?.activate(self)
        palette.isHidden = true

        if textField != nil {
            commitText()
            return
        }

        // Existing annotation: drag to move, double-click a text to edit it again, Delete removes.
        if state == .selected, tool == .move || tool == .text, let i = shapeIndex(at: p) {
            if event.clickCount == 2, shapes[i].tool == .text { editTextShape(at: i); return }
            selectedShape = i
            drag = .moveShape(i, startPoints: shapes[i].points, start: p)
            NSCursor.closedHand.push()
            return
        }
        selectedShape = nil

        if state == .selected {
            if tool == .move {
                if let hit = handleRects().first(where: { $0.1.insetBy(dx: -4, dy: -4).contains(p) }) {
                    drag = .resize(hit.0, startRect: selection)
                    return
                }
                if selection.contains(p) {
                    drag = .move(startRect: selection, start: p)
                    NSCursor.closedHand.push()
                    return
                }
            } else if selection.insetBy(dx: -2, dy: -2).contains(p) {
                if tool == .text {
                    beginText(at: p)
                    return
                }
                currentShape = Shape(tool: tool, points: [p, p], color: color, lineWidth: lineWidth)
                drag = .draw
                needsDisplay = true
                return
            }
        }

        // start a brand-new selection
        shapes = []
        currentShape = nil
        state = .selecting
        selection = CGRect(origin: p, size: .zero)
        drag = .select(start: p)
        toolbar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .none:
            return
        case .select(let start):
            selection = rect(from: start, to: p)
        case .move(let startRect, let start):
            var r = startRect.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            selection = r
            layoutToolbar()
        case .resize(let h, let startRect):
            var minX = startRect.minX, maxX = startRect.maxX, minY = startRect.minY, maxY = startRect.maxY
            switch h {
            case .topLeft: minX = p.x; maxY = p.y
            case .top: maxY = p.y
            case .topRight: maxX = p.x; maxY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; minY = p.y
            case .bottom: minY = p.y
            case .bottomLeft: minX = p.x; minY = p.y
            case .left: minX = p.x
            }
            selection = rect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
            layoutToolbar()
        case .moveShape(let i, let startPoints, let start):
            guard i < shapes.count else { return }
            shapes[i].points = startPoints.map { CGPoint(x: $0.x + p.x - start.x, y: $0.y + p.y - start.y) }
        case .draw:
            guard var s = currentShape else { return }
            switch s.tool {
            case .pen, .marker:
                s.points.append(p)
            default:
                s.points[1] = p
            }
            currentShape = s
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .select:
            if selection.width < 4 || selection.height < 4 {
                if let r = hoverWindowRect, r.width >= 4, r.height >= 4 {
                    selection = r.integral        // plain click → the window under the cursor
                    state = .selected
                } else {
                    state = .idle
                    selection = .zero
                }
            } else {
                state = .selected
                selection = selection.integral
            }
        case .move:
            NSCursor.pop()
            selection = selection.integral
        case .resize:
            selection = selection.integral
            if selection.width < 4 || selection.height < 4 {
                state = .idle; selection = .zero; shapes = []
            }
        case .draw:
            if let s = currentShape { shapes.append(s); redoStack = [] }
            currentShape = nil
        case .moveShape:
            NSCursor.pop()
        case .none:
            break
        }
        drag = .none
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard state == .idle else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = windowFrames.first { $0.contains(p) }?.intersection(bounds)
        if r != hoverWindowRect { hoverWindowRect = r; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverWindowRect != nil { hoverWindowRect = nil; needsDisplay = true }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Lightshot: right-click cancels
        if state == .idle { session?.cancel() } else { reset() }
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        // Virtual key codes are layout-independent, so everything works with a Korean input source too.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)

        if code == 53 { // esc: text edit → tool → shape selection → selection → close
            if textField != nil { cancelText() }
            else if state == .selected && tool != .move { tool = .move; palette.isHidden = true }
            else if selectedShape != nil { selectedShape = nil }
            else if state != .idle { reset() }
            else { session?.cancel() }
            return
        }
        if code == 51 || code == 117 { // delete / forward delete
            if let i = selectedShape, i < shapes.count {
                redoStack.append(shapes.remove(at: i))
                selectedShape = nil
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
            }
            return
        }
        if (123...126).contains(code), state == .selected { // arrows nudge selection or the selected shape
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: CGPoint
            switch code {
            case 123: d = CGPoint(x: -step, y: 0)
            case 124: d = CGPoint(x: step, y: 0)
            case 125: d = CGPoint(x: 0, y: -step)
            default:  d = CGPoint(x: 0, y: step)
            }
            if let i = selectedShape, i < shapes.count {
                shapes[i] = shapes[i].translated(by: d)
            } else {
                var r = selection.offsetBy(dx: d.x, dy: d.y)
                r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
                r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
                selection = r
                layoutToolbar()
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if code == 36 || code == 76 { // return / enter
            if state == .selected { copyToClipboard() }
            return
        }
        if flags.contains(.command) {
            switch code {
            case 8:  if state == .selected { copyToClipboard() }                       // C
            case 1:  if state == .selected { flags.contains(.shift) ? showShareMenu() : saveToFile() } // S
            case 6:  flags.contains(.shift) ? redoLast() : undoLast()                  // Z / ⇧Z
            case 0:  selectWholeScreen()                                               // A
            case 24, 69: if tool == .text { stepTextSize(+1) }                         // = / keypad +
            case 27, 78: if tool == .text { stepTextSize(-1) }                         // - / keypad -
            default: break
            }
            return
        }
        guard state == .selected, flags.isEmpty || flags == .shift else { return }
        let map: [Int: Tool] = [35: .pen, 37: .line, 0: .arrow, 15: .rect, 14: .ellipse, 46: .marker, 17: .text, 9: .move]
        if let t = map[code] { tool = t }
    }

    /// ⌘A arrives as the Edit-menu `selectAll:` action when a main menu exists.
    override func selectAll(_ sender: Any?) { selectWholeScreen() }

    private func selectWholeScreen() {
        state = .selected
        selection = bounds
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: text tool

    private func stepTextSize(_ dir: Int) {
        textSize = min(max(textSize + CGFloat(dir * 2), 8), 200)
    }

    private func beginText(at p: CGPoint, initialText: String = "") {
        let height = textSize * 1.5
        let tf = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - height + textSize * 0.3, width: 140, height: height))
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = self
        tf.lineBreakMode = .byClipping
        tf.stringValue = initialText
        addSubview(tf)
        textField = tf
        applyTextFieldStyle()
        window?.makeFirstResponder(tf)
        if !initialText.isEmpty, let editor = tf.currentEditor() {
            editor.selectedRange = NSRange(location: (initialText as NSString).length, length: 0)
        }
        needsDisplay = true
    }

    /// Re-open an existing text annotation for editing (double-click). Its own size/colour/style
    /// become the current settings so the options bar reflects them.
    private func editTextShape(at i: Int) {
        guard i < shapes.count, shapes[i].tool == .text, let o = shapes[i].points.first else { return }
        let sh = shapes.remove(at: i)
        color = sh.color
        textSize = sh.fontSize
        textStyle = sh.textStyle
        boxColor = sh.boxColor
        boxAlpha = sh.boxAlpha
        tool = .text
        beginText(at: CGPoint(x: o.x, y: o.y - textSize * 0.1), initialText: sh.text)
        alignEditor(toOrigin: o)
    }

    /// Top-left corner (in this view's coordinates) of the glyphs as the field editor currently
    /// lays them out — so the committed annotation lands exactly where the text was while typing.
    private var editingTextOrigin: CGPoint? {
        guard let tf = textField else { return nil }
        if let editor = tf.currentEditor() as? NSTextView, let lm = editor.layoutManager, let tc = editor.textContainer {
            lm.ensureLayout(for: tc)
            var line = lm.usedRect(for: tc)
            if lm.numberOfGlyphs > 0 { line = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil) }
            else { line.origin.x += tc.lineFragmentPadding }
            let topLeftInEditor = NSPoint(x: editor.textContainerOrigin.x + line.minX,
                                          y: editor.textContainerOrigin.y + line.minY)
            return convert(topLeftInEditor, from: editor)
        }
        return CGPoint(x: tf.frame.minX + 2, y: tf.frame.maxY - textSize * 0.2)
    }

    /// Shift the editing field so its glyphs start exactly at `target` (used when re-editing).
    private func alignEditor(toOrigin target: CGPoint) {
        guard let tf = textField, let cur = editingTextOrigin else { return }
        tf.frame = tf.frame.offsetBy(dx: target.x - cur.x, dy: target.y - cur.y)
        needsDisplay = true
    }

    private var editingText: String { textField?.stringValue ?? "" }

    /// Live-preview the current size / colour in the editing field and grow it with the text.
    /// While editing, the field is drawn by the shared field editor (an NSTextView), so its
    /// attributes have to be updated too — changing only the NSTextField does nothing visible.
    private func applyTextFieldStyle() {
        guard let tf = textField else { return }
        let font = NSFont.boldSystemFont(ofSize: textSize)

        tf.font = font
        tf.textColor = color
        tf.drawsBackground = false
        tf.placeholderAttributedString = NSAttributedString(string: "텍스트 입력…",
            attributes: [.foregroundColor: color.withAlphaComponent(0.5), .font: font])

        let height = textSize * 1.5
        let textW = NSAttributedString(string: editingText.isEmpty ? "텍스트 입력…" : editingText,
                                       attributes: [.font: font]).size().width
        let width = textW + textSize + 24
        tf.frame = NSRect(x: tf.frame.minX, y: tf.frame.maxY - height, width: width, height: height)

        if let editor = tf.currentEditor() as? NSTextView {
            editor.font = font
            editor.textColor = color
            editor.insertionPointColor = color
            editor.drawsBackground = false
            editor.typingAttributes = [.font: font, .foregroundColor: color]
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: storage.length))
            }
            editor.needsDisplay = true
        }
        tf.needsDisplay = true
        needsDisplay = true // the box preview is drawn by this view, behind the field
    }

    func controlTextDidChange(_ obj: Notification) {
        applyTextFieldStyle()
    }

    private func commitText() {
        guard let tf = textField else { return }
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let origin = editingTextOrigin ?? CGPoint(x: tf.frame.minX + 2, y: tf.frame.maxY - textSize * 0.2)
            shapes.append(Shape(tool: .text, points: [origin], color: color, lineWidth: lineWidth,
                                text: text, fontSize: textSize, textStyle: textStyle,
                                boxColor: boxColor, boxAlpha: boxAlpha))
            redoStack = []
        }
        tf.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dim = NSColor.black.withAlphaComponent(0.45)
        if state == .idle {
            dim.setFill()
            if let r = hoverWindowRect {
                // lighten the window under the cursor and outline it: a click selects it
                let path = NSBezierPath(rect: bounds)
                path.append(NSBezierPath(rect: r))
                path.windingRule = .evenOdd
                path.fill()
                NSColor.black.withAlphaComponent(0.18).setFill()
                r.fill()
                let o = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                o.lineWidth = 2
                NSColor.white.withAlphaComponent(0.9).setStroke()
                o.stroke()
            } else {
                bounds.fill()
            }
            drawIdleHint()
            return
        }

        // dim everything except the selection
        dim.setFill()
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: selection))
        path.windingRule = .evenOdd
        path.fill()

        // annotations (clipped to selection)
        ctx.saveGState()
        ctx.clip(to: selection)
        ShapeRenderer.draw(shapes, in: ctx)
        if let c = currentShape { ShapeRenderer.draw(c, in: ctx) }
        if textField != nil, let o = editingTextOrigin {
            // preview of the exact area the background box will cover
            let t = editingText.isEmpty ? "텍스트 입력…" : editingText
            let box = Shape.boxRect(text: t, fontSize: textSize, style: textStyle, origin: o)
            let r = Shape.boxCornerRadius(fontSize: textSize)
            if textStyle.contains(.box) {
                ctx.setFillColor(boxColor.withAlphaComponent(boxAlpha).cgColor)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        // highlighted annotation (selection tool)
        if let i = selectedShape, i < shapes.count {
            let b = shapes[i].bounds.insetBy(dx: -3, dy: -3)
            let hl = NSBezierPath(roundedRect: b, xRadius: 4, yRadius: 4)
            hl.lineWidth = 1
            hl.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            hl.stroke()
        }

        // selection border
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()

        // handles
        if state == .selected && tool == .move {
            for (_, r) in handleRects() {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: r).fill()
                NSColor.black.withAlphaComponent(0.5).setStroke()
                NSBezierPath(ovalIn: r).stroke()
            }
        }

        drawSizeLabel()
    }

    private func drawSizeLabel() {
        let s = pixelScale
        let w = Int((selection.width * s).rounded()), h = Int((selection.height * s).rounded())
        let str = NSAttributedString(string: "\(w) × \(h)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = str.size()
        let pad: CGFloat = 5
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 4)
        if origin.y + size.height + pad * 2 > bounds.height { origin.y = selection.maxY - size.height - pad * 2 - 4 }
        if origin.x + size.width + pad * 2 > bounds.width { origin.x = bounds.width - size.width - pad * 2 }
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad)
        NSColor(calibratedWhite: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        str.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2))
    }

    private func drawIdleHint() {
        let str = NSAttributedString(string: "드래그로 영역 선택  ·  클릭하면 창 선택  ·  ⌘A 전체 화면  ·  Esc 취소", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ])
        let size = str.size()
        let pad: CGFloat = 12
        let box = NSRect(x: (bounds.width - size.width) / 2 - pad, y: bounds.height * 0.5 - size.height / 2 - pad / 2,
                         width: size.width + pad * 2, height: size.height + pad)
        NSColor(calibratedWhite: 0.1, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        str.draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad / 2))
    }

    // MARK: demo / screenshots (used by `SHOTPARK_DEMO` env var only)

    func applyDemo(selection rect: CGRect, shapes demoShapes: [Shape]) {
        state = .selected
        selection = rect.integral
        shapes = demoShapes
        tool = .move
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: export

    func renderResult() -> NSImage? {
        guard state == .selected, selection.width >= 1, selection.height >= 1 else { return nil }
        commitText()
        let s = pixelScale
        let pixelRect = CGRect(x: selection.minX * s,
                               y: (bounds.height - selection.maxY) * s,
                               width: selection.width * s,
                               height: selection.height * s).integral
        guard let cropped = screenshot.cropping(to: pixelRect) else { return nil }
        let w = cropped.width, h = cropped.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: CGFloat(w) / selection.width, y: CGFloat(h) / selection.height)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ShapeRenderer.draw(shapes, in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: selection.size)
    }

    func copyToClipboard() {
        guard let image = renderResult() else { return }
        session?.finish(with: image, mode: .copy)
    }

    func saveToFile() {
        guard let image = renderResult() else { return }
        session?.finish(with: image, mode: .save)
    }
}

enum Preferences {
    private static let colorKey = "annotationColor"
    private static let textSizeKey = "annotationTextSize"
    private static let textStyleKey = "annotationTextStyles"

    static var textSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: textSizeKey); return v > 0 ? CGFloat(v) : 24 }
        set { UserDefaults.standard.set(Double(newValue), forKey: textSizeKey) }
    }
    static var textStyle: TextStyles {
        get {
            guard UserDefaults.standard.object(forKey: textStyleKey) != nil else { return .shadow }
            return TextStyles(rawValue: UserDefaults.standard.integer(forKey: textStyleKey))
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: textStyleKey) }
    }
    private static let lineWidthKey = "annotationLineWidth"
    static var lineWidth: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: lineWidthKey); return v > 0 ? CGFloat(v) : 4 }
        set { UserDefaults.standard.set(Double(newValue), forKey: lineWidthKey) }
    }
    private static let boxColorKey = "annotationBoxColor"
    private static let boxAlphaKey = "annotationBoxAlpha"
    static var boxColor: NSColor {
        get {
            if let data = UserDefaults.standard.data(forKey: boxColorKey),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return c }
            return .white
        }
        set {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: boxColorKey)
            }
        }
    }
    static var boxAlpha: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: boxAlphaKey); return v > 0 ? CGFloat(v) : 0.85 }
        set { UserDefaults.standard.set(Double(newValue), forKey: boxAlphaKey) }
    }

    static var color: NSColor {
        get {
            if let data = UserDefaults.standard.data(forKey: colorKey),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                return c
            }
            return ColorPaletteView.colors[0]
        }
        set {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: newValue, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: colorKey)
            }
        }
    }
}
