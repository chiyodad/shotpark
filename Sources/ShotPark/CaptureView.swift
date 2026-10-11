import AppKit

/// Full-screen overlay view: region selection, annotation canvas, toolbar host.
/// Coordinates are standard AppKit (origin bottom-left, points).
final class CaptureView: NSView, NSTextViewDelegate {
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
    /// True while a drag that began by clicking outside an existing selection is in progress.
    private var clickOutsideSelection = false

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
        didSet { toolbar.currentColor = color; palette.selected = color; strokeOptions.color = color; Preferences.color = color; applyTextFieldStyle(); window?.invalidateCursorRects(for: self) }
    }
    var lineWidth: CGFloat = Preferences.lineWidth {
        didSet { strokeOptions.lineWidth = lineWidth; Preferences.lineWidth = lineWidth }
    }
    var dashed: Bool = Preferences.dashed {
        didSet { strokeOptions.dashed = dashed; Preferences.dashed = dashed }
    }
    var arrowHead: ArrowHead = Preferences.arrowHead {
        didSet { strokeOptions.arrowHead = arrowHead; Preferences.arrowHead = arrowHead }
    }

    private let toolbar = ToolbarView()
    private let palette = ColorPaletteView()
    private let textOptions = TextOptionsView()
    private let strokeOptions = StrokeOptionsView()
    private let emojiOptions = EmojiOptionsView()
    var emoji: String = Preferences.emoji { didSet { emojiOptions.emoji = emoji; Preferences.emoji = emoji; window?.invalidateCursorRects(for: self) } }
    var emojiSize: CGFloat = Preferences.emojiSize { didSet { emojiOptions.emojiSize = emojiSize; Preferences.emojiSize = emojiSize; window?.invalidateCursorRects(for: self) } }
    private var textEditor: AnnotationTextView?

    var textSize: CGFloat = Preferences.textSize {
        didSet { textOptions.fontSize = textSize; Preferences.textSize = textSize; applyTextFieldStyle(); window?.invalidateCursorRects(for: self) }
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
        strokeOptions.dashed = dashed
        strokeOptions.arrowHead = arrowHead
        strokeOptions.onDashed = { [weak self] in self?.dashed = $0 }
        strokeOptions.onArrowHead = { [weak self] in self?.arrowHead = $0 }
        addSubview(strokeOptions)

        emojiOptions.isHidden = true
        emojiOptions.emoji = emoji
        emojiOptions.emojiSize = emojiSize
        emojiOptions.recents = Preferences.recentEmojis
        emojiOptions.onPick = { [weak self] e in
            guard let self else { return }
            self.emoji = e
            var r = Preferences.recentEmojis.filter { $0 != e }
            r.insert(e, at: 0)
            Preferences.recentEmojis = Array(r.prefix(10))
            self.emojiOptions.recents = Preferences.recentEmojis
            self.layoutToolbar()
        }
        emojiOptions.onSize = { [weak self] in self?.emojiSize = $0 }
        emojiOptions.onFocusReturn = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        addSubview(emojiOptions)
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
        emojiOptions.isHidden = true
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
            } else if tool == .emoji {
                // The stamp itself is the cursor, so you see exactly what you're about to place.
                addCursorRect(selection, cursor: emojiCursor())
            } else if tool == .number {
                addCursorRect(selection, cursor: numberCursor())
            }
            if tool == .move || tool == .text {
                for r in textShapeRects() { addCursorRect(r.intersection(selection), cursor: .openHand) }
            }
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private var emojiCursorCache: (key: String, cursor: NSCursor)?
    /// A cursor showing the current emoji at (roughly) its stamp size, hotspot in the centre.
    private func emojiCursor() -> NSCursor {
        let side = min(max(emojiSize * 0.8, 24), 64)
        let key = "\(emoji)@\(side)"
        if let c = emojiCursorCache, c.key == key { return c.cursor }
        let font = NSFont.systemFont(ofSize: side * 0.78)
        let str = NSAttributedString(string: emoji, attributes: [.font: font])
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let sz = str.size()
            // soft shadow so the cursor stays visible on light backgrounds
            let shadow = NSShadow(); shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.set()
            str.draw(at: NSPoint(x: (rect.width - sz.width) / 2, y: (rect.height - sz.height) / 2))
            return true
        }
        let cursor = NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
        emojiCursorCache = (key, cursor)
        return cursor
    }

    private var numberCursorCache: (key: String, cursor: NSCursor)?
    /// A cursor showing the next number stamp exactly as it will be drawn (same renderer), hotspot in the centre.
    private func numberCursor() -> NSCursor {
        let next = (shapes.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
        let probe = Shape(tool: .number, points: [.zero], color: color, lineWidth: lineWidth, text: "\(next)", fontSize: textSize)
        let r = min(probe.stampRadius, 30)
        let side = (r * 2 + 8).rounded()
        let key = "\(next)@\(side)@\(color.hexString)"
        if let c = numberCursorCache, c.key == key { return c.cursor }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var sh = probe
            sh.points = [CGPoint(x: rect.midX, y: rect.midY)]
            sh.fontSize = r / 0.7 // stampRadius = max(12, fontSize * 0.7)
            ShapeRenderer.draw(sh, in: ctx)
            return true
        }
        let cursor = NSCursor(image: img, hotSpot: NSPoint(x: side / 2, y: side / 2))
        numberCursorCache = (key, cursor)
        return cursor
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
        guard state == .selected else { toolbar.isHidden = true; palette.isHidden = true; textOptions.isHidden = true; strokeOptions.isHidden = true; emojiOptions.isHidden = true; return }
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
        textOptions.isHidden = !(tool == .text || tool == .number)
        if tool == .text || tool == .number { place(textOptions) }
        let drawing: Set<Tool> = [.pen, .line, .arrow, .rect, .ellipse, .marker]
        strokeOptions.isHidden = !drawing.contains(tool)
        strokeOptions.showsDash = [.line, .arrow, .rect, .ellipse].contains(tool)
        strokeOptions.showsHead = tool == .arrow
        if drawing.contains(tool) { place(strokeOptions) }
        emojiOptions.isHidden = tool != .emoji
        if tool == .emoji { place(emojiOptions) }
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
            let item = NSMenuItem(title: L("\(target.name)(으)로 보내기", "Send to \(target.name)"), action: #selector(shareToApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.name
            if let icon = target.appURL.map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            }
            menu.addItem(item)
        }
        if !ShareTarget.installed.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: L("다른 앱으로 공유… (메일 · 메시지 · AirDrop)", "Share to another app… (Mail · Messages · AirDrop)"), action: #selector(shareViaSystem), keyEquivalent: "")
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
        if textEditor != nil { cancelText(); return }
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

        if textEditor != nil {
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
                if tool == .emoji {
                    shapes.append(Shape(tool: .emoji, points: [p], color: color, lineWidth: lineWidth,
                                        text: emoji, fontSize: emojiSize))
                    redoStack = []
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    return
                }
                if tool == .number {
                    let next = (shapes.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
                    shapes.append(Shape(tool: .number, points: [p], color: color, lineWidth: lineWidth,
                                        text: "\(next)", fontSize: textSize))
                    redoStack = []
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    return
                }
                currentShape = Shape(tool: tool, points: [p, p], color: color, lineWidth: lineWidth, dashed: dashed, arrowHead: arrowHead)
                drag = .draw
                needsDisplay = true
                return
            }
        }

        // start a brand-new selection
        clickOutsideSelection = state == .selected
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
                // A plain click. Outside an existing selection it just clears that selection;
                // from the idle screen it grabs the window under the cursor (looked up fresh,
                // never from a stale hover rect).
                let p = clamp(convert(event.locationInWindow, from: nil))
                let under = windowFrames.first { $0.contains(p) }?.intersection(bounds)
                if !clickOutsideSelection, let r = under, r.width >= 4, r.height >= 4 {
                    selection = r.integral
                    state = .selected
                } else {
                    state = .idle
                    selection = .zero
                    hoverWindowRect = under
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

    /// Compute the hovered window from the current mouse position (called once the overlay is up).
    func refreshHover() {
        guard state == .idle, let win = window else { return }
        let p = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        hoverWindowRect = bounds.contains(p) ? windowFrames.first { $0.contains(p) }?.intersection(bounds) : nil
        needsDisplay = true
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
            if textEditor != nil { cancelText() }
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
            case 24, 69: if tool == .text || tool == .number { stepTextSize(+1) }                         // = / keypad +
            case 27, 78: if tool == .text || tool == .number { stepTextSize(-1) }                         // - / keypad -
            default: break
            }
            return
        }
        guard state == .selected, flags.isEmpty || flags == .shift else { return }
        let map: [Int: Tool] = [35: .pen, 37: .line, 0: .arrow, 15: .rect, 14: .ellipse, 46: .marker, 17: .text, 45: .number, 1: .emoji, 9: .move]
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
        let tv = AnnotationTextView(frame: NSRect(x: p.x - 2, y: p.y - height + textSize * 0.3, width: 160, height: height))
        tv.delegate = self
        tv.string = initialText
        addSubview(tv)
        textEditor = tv
        applyTextFieldStyle()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (initialText as NSString).length, length: 0))
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

    /// Top-left corner (in this view's coordinates) of the glyphs as the editor currently lays
    /// them out — so the committed annotation lands exactly where the text was while typing.
    private var editingTextOrigin: CGPoint? {
        guard let tv = textEditor, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        var line = lm.usedRect(for: tc)
        if lm.numberOfGlyphs > 0 { line = lm.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: nil) }
        else { line.origin.x += tc.lineFragmentPadding }
        let topLeftInEditor = NSPoint(x: tv.textContainerOrigin.x + line.minX,
                                      y: tv.textContainerOrigin.y + line.minY)
        return convert(topLeftInEditor, from: tv)
    }

    /// Shift the editor so its glyphs start exactly at `target` (used when re-editing).
    private func alignEditor(toOrigin target: CGPoint) {
        guard let tv = textEditor, let cur = editingTextOrigin else { return }
        tv.frame = tv.frame.offsetBy(dx: target.x - cur.x, dy: target.y - cur.y)
        needsDisplay = true
    }

    private var editingText: String { textEditor?.string ?? "" }

    /// Apply the current size / colour to the editor and grow it to fit the text (multi-line).
    private func applyTextFieldStyle() {
        guard let tv = textEditor, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let font = NSFont.boldSystemFont(ofSize: textSize)
        // Same attributes the final rendering uses (shadow / outline included) so the preview matches.
        let attrs = Shape.textAttributes(color: color, fontSize: textSize, style: textStyle)
        tv.font = font
        tv.textColor = color
        tv.insertionPointColor = color
        tv.typingAttributes = attrs
        if let storage = tv.textStorage, storage.length > 0 {
            let all = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.shadow, range: all)
            storage.removeAttribute(.strokeColor, range: all)
            storage.removeAttribute(.strokeWidth, range: all)
            storage.addAttributes(attrs, range: all)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let minW = NSAttributedString(string: L("텍스트 입력…", "Type text…"), attributes: [.font: font]).size().width
        let w = max(used.width, minW) + tc.lineFragmentPadding * 2 + textSize + 8
        let h = max(used.height, font.ascender - font.descender + font.leading) + 4
        tv.frame = NSRect(x: tv.frame.minX, y: tv.frame.maxY - h, width: w, height: h)
        tv.needsDisplay = true
        needsDisplay = true // the box preview + placeholder are drawn by this view, behind the editor
    }

    func textDidChange(_ notification: Notification) {
        applyTextFieldStyle()
    }

    private func commitText() {
        guard let tv = textEditor else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let origin = editingTextOrigin ?? CGPoint(x: tv.frame.minX + 2, y: tv.frame.maxY - textSize * 0.2)
            shapes.append(Shape(tool: .text, points: [origin], color: color, lineWidth: lineWidth,
                                text: text, fontSize: textSize, textStyle: textStyle,
                                boxColor: boxColor, boxAlpha: boxAlpha))
            redoStack = []
        }
        tv.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func cancelText() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Enter commits, ⇧Enter / ⌥Enter insert a line break, Esc cancels.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            commitText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dim = NSColor.black.withAlphaComponent(0.45)
        if state == .idle {
            dim.setFill()
            bounds.fill()
            if let r = hoverWindowRect {
                // outline the window under the cursor (a click selects it) — the dim stays uniform
                // so nothing flashes when the overlay appears
                let o = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                o.lineWidth = 2
                o.setLineDash([6, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.85).setStroke()
                o.stroke()
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
        if textEditor != nil, let o = editingTextOrigin {
            // preview of the exact area the background box will cover
            let t = editingText.isEmpty ? L("텍스트 입력…", "Type text…") : editingText
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
            if editingText.isEmpty {
                let ph = NSAttributedString(string: L("텍스트 입력…  (⇧↩ 줄바꿈)", "Type text…  (⇧↩ new line)"), attributes: [
                    .font: NSFont.boldSystemFont(ofSize: textSize), .foregroundColor: color.withAlphaComponent(0.45)])
                ph.draw(at: Shape.textRect(text: " ", fontSize: textSize, style: textStyle, origin: o).origin)
            }
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
        // One line per action, each with an SF Symbol in front of it.
        let rows: [(String, String)] = [
            ("rectangle.dashed",       L("드래그로 영역 선택", "Drag to select a region")),
            ("macwindow",              L("클릭하여 창 선택", "Click to grab a window")),
            ("arrow.up.left.and.arrow.down.right", L("⌘A  전체 화면", "⌘A  whole screen")),
            ("xmark.circle",           L("Esc  취소", "Esc  cancel")),
        ]
        let font = NSFont.systemFont(ofSize: 15, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
        let icon: CGFloat = 20, gap: CGFloat = 10, rowH: CGFloat = 28, pad: CGFloat = 16
        let textW = rows.map { NSAttributedString(string: $0.1, attributes: attrs).size().width }.max() ?? 0
        let boxW = pad + icon + gap + textW + pad
        let boxH = pad + rowH * CGFloat(rows.count) + pad - 6
        let box = NSRect(x: ((bounds.width - boxW) / 2).rounded(), y: ((bounds.height - boxH) / 2).rounded(), width: boxW, height: boxH)
        NSColor(calibratedWhite: 0.1, alpha: 0.82).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.92)]))
        for (i, row) in rows.enumerated() {
            // top row first (view is non-flipped, so count down from the top of the box)
            let y = box.maxY - pad - rowH * CGFloat(i + 1) + 6
            if let img = NSImage(systemSymbolName: row.0, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let sz = img.size
                let r = NSRect(x: box.minX + pad + (icon - sz.width) / 2, y: y + (rowH - sz.height) / 2, width: sz.width, height: sz.height)
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            }
            let str = NSAttributedString(string: row.1, attributes: attrs)
            let th = str.size().height
            str.draw(at: CGPoint(x: box.minX + pad + icon + gap, y: y + (rowH - th) / 2))
        }
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
    private static let paletteKey = "annotationPalette"
    /// 10 annotation colours shown in the palette, stored as hex strings. Default: `ColorPaletteView.defaultColors`.
    static var palette: [NSColor] {
        get {
            let defaults = ColorPaletteView.defaultColors
            guard let hex = UserDefaults.standard.stringArray(forKey: paletteKey), hex.count == defaults.count else { return defaults }
            let parsed = hex.compactMap(NSColor.init(hex:))
            return parsed.count == defaults.count ? parsed : defaults
        }
        set { UserDefaults.standard.set(newValue.map { $0.hexString }, forKey: paletteKey) }
    }
    static func resetPalette() { UserDefaults.standard.removeObject(forKey: paletteKey) }

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
    private static let dashedKey = "annotationDashed"
    private static let arrowHeadKey = "annotationArrowHead"
    static var dashed: Bool {
        get { UserDefaults.standard.bool(forKey: dashedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dashedKey) }
    }
    static var arrowHead: ArrowHead {
        get { ArrowHead(rawValue: UserDefaults.standard.integer(forKey: arrowHeadKey)) ?? .triangle }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: arrowHeadKey) }
    }
    private static let lineWidthKey = "annotationLineWidth"
    static var lineWidth: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: lineWidthKey); return v > 0 ? CGFloat(v) : 4 }
        set { UserDefaults.standard.set(Double(newValue), forKey: lineWidthKey) }
    }
    private static let emojiKey = "stampEmoji"
    private static let emojiSizeKey = "stampEmojiSize"
    private static let recentEmojisKey = "stampRecentEmojis"
    static var emoji: String {
        get { UserDefaults.standard.string(forKey: emojiKey) ?? "👍" }
        set { UserDefaults.standard.set(newValue, forKey: emojiKey) }
    }
    static var emojiSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: emojiSizeKey); return v > 0 ? CGFloat(v) : 44 }
        set { UserDefaults.standard.set(Double(newValue), forKey: emojiSizeKey) }
    }
    static var recentEmojis: [String] {
        get { UserDefaults.standard.stringArray(forKey: recentEmojisKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentEmojisKey) }
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


extension NSColor {
    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - self-test (SHOTPARK_SELFTEST=1): drives the real overlay with synthetic events

extension CaptureView {
    private func ev(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    private func click(_ p: CGPoint, clicks: Int = 1) { mouseDown(with: ev(.leftMouseDown, p, clicks: clicks)); mouseUp(with: ev(.leftMouseUp, p, clicks: clicks)) }
    private func dragFrom(_ a: CGPoint, to b: CGPoint) {
        mouseDown(with: ev(.leftMouseDown, a))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        mouseDragged(with: ev(.leftMouseDragged, mid))
        mouseDragged(with: ev(.leftMouseDragged, b))
        mouseUp(with: ev(.leftMouseUp, b))
    }
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                                    context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) { keyDown(with: e) }
    }

    /// Returns a list of "PASS …" / "FAIL …" lines.
    func runSelfTest() -> [String] {
        var out: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { out.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [\(detail)]")) }
        let H = bounds.height, W = bounds.width
        let fakeWindow = CGRect(x: 0, y: 0, width: W, height: H) // a full-screen "window" under the cursor everywhere
        windowFrames = [fakeWindow]

        // 1. drag-select a region
        out.append("INFO bounds=\(bounds) win=\(window?.frame ?? .zero) key=\(window?.isKeyWindow ?? false) screens=\(NSScreen.screens.map { $0.frame })")
        mouseDown(with: ev(.leftMouseDown, CGPoint(x: 100, y: H - 100)))
        out.append("INFO after down: state=\(state) sel=\(selection)")
        mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 400, y: H - 300)))
        out.append("INFO after drag: state=\(state) sel=\(selection)")
        mouseUp(with: ev(.leftMouseUp, CGPoint(x: 400, y: H - 300)))
        out.append("INFO after up: state=\(state) sel=\(selection)")
        check("drag selects region", state == .selected && selection.width == 300 && selection.height == 200, "\(selection)")

        // 2. BUG: click outside selection must clear it, not grab the (full-screen) window under the cursor
        click(CGPoint(x: 50, y: H - 50))
        check("click outside selection → idle (not whole-screen)", state == .idle && selection == .zero, "state=\(state) sel=\(selection)")

        // 3. idle click grabs the window under the cursor (fresh lookup)
        windowFrames = [CGRect(x: 200, y: 200, width: 300, height: 150)]
        click(CGPoint(x: 250, y: 250))
        check("idle click selects window under cursor", state == .selected && selection == CGRect(x: 200, y: 200, width: 300, height: 150), "\(selection)")
        click(CGPoint(x: 10, y: 10))      // outside → idle again
        check("click outside again → idle", state == .idle)
        windowFrames = []
        click(CGPoint(x: 10, y: 10))
        check("idle click with no window stays idle", state == .idle)

        // 4. number stamps: 1, 2, 3 and the cursor for the next one
        dragFrom(CGPoint(x: 100, y: H - 100), to: CGPoint(x: 500, y: H - 400))
        tool = .number
        click(CGPoint(x: 150, y: H - 150)); click(CGPoint(x: 200, y: H - 150)); click(CGPoint(x: 250, y: H - 150))
        check("number stamps 1,2,3", shapes.map(\.text) == ["1", "2", "3"], "\(shapes.map(\.text))")
        let nc = numberCursor()
        check("number cursor built", nc.image.size.width > 0 && nc.hotSpot.x > 0)
        undoLast()
        check("undo removes last stamp", shapes.map(\.text) == ["1", "2"])
        click(CGPoint(x: 300, y: H - 150))
        check("next number after undo is 3", shapes.last?.text == "3")
        key(53) // Esc → tool back to move
        check("Esc leaves tool → move", tool == .move && state == .selected)

        // 5. emoji stamp + cursor + 10-slot bar
        tool = .emoji
        let before = emojiOptions.choiceCount
        emojiOptions.onPick?("🦄")
        emojiOptions.onPick?("🐙")
        check("emoji bar stays at 10 slots", before == 10 && emojiOptions.choiceCount == 10, "before=\(before) after=\(emojiOptions.choiceCount)")
        check("newest emoji is first", emojiOptions.firstChoice == "🐙", "\(emojiOptions.firstChoice ?? "-")")
        check("current emoji follows pick", emoji == "🐙")
        click(CGPoint(x: 400, y: H - 200))
        check("emoji stamp placed", shapes.last?.tool == .emoji && shapes.last?.text == "🐙")
        let ec = emojiCursor()
        check("emoji cursor built", ec.image.size.width >= 24)
        key(53)

        // 5b. dashed + circle-head arrow, then back to defaults
        tool = .arrow
        dashed = true; arrowHead = .circle
        dragFrom(CGPoint(x: 150, y: H - 300), to: CGPoint(x: 350, y: H - 350))
        check("dashed circle-head arrow placed", shapes.last?.tool == .arrow && shapes.last?.dashed == true && shapes.last?.arrowHead == .circle)
        check("dash/head remembered in prefs", Preferences.dashed == true && Preferences.arrowHead == .circle)
        tool = .rect
        dragFrom(CGPoint(x: 150, y: H - 380), to: CGPoint(x: 250, y: H - 420))
        check("dashed rect placed", shapes.last?.tool == .rect && shapes.last?.dashed == true)
        dashed = false; arrowHead = .triangle
        tool = .line
        dragFrom(CGPoint(x: 300, y: H - 300), to: CGPoint(x: 450, y: H - 350))
        check("solid line after toggling off", shapes.last?.tool == .line && shapes.last?.dashed == false)
        key(53)
        check("version compare", UpdateChecker.isNewer("1.10.0", than: "1.9.2") && !UpdateChecker.isNewer("1.9.2", than: "1.9.2") && !UpdateChecker.isNewer("1.9.1", than: "1.9.2"))

        // 6. click outside with annotations → idle and annotations cleared
        click(CGPoint(x: 20, y: 20))
        check("click outside clears selection + shapes", state == .idle && shapes.isEmpty)

        // 7. stepped Esc from a fresh selection: idle → (session cancel is not exercised here)
        dragFrom(CGPoint(x: 100, y: H - 100), to: CGPoint(x: 300, y: H - 200))
        key(53)
        check("Esc on selection → idle", state == .idle)
        return out
    }
}
