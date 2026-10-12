import AppKit

/// Full-screen overlay view: region selection, annotation canvas, toolbar host.
/// Coordinates are standard AppKit (origin bottom-left, points).
final class CaptureView: NSView, NSTextViewDelegate {
    enum State { case idle, selecting, selected }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private enum Drag {
        var isIdle: Bool { if case .none = self { return true } else { return false } }
        case none
        case select(start: CGPoint)
        case move(startRect: CGRect, start: CGPoint)
        case resize(Handle, startRect: CGRect)
        case draw
        case moveShape(Int, startPoints: [CGPoint], start: CGPoint)
        case scaleShape(Int, startSize: CGFloat, center: CGPoint, startDist: CGFloat)
        case erase
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
    /// Eraser: shapes removed by the current drag, and per-gesture records so ⌘Z can bring them back.
    private var eraseGesture: [(Int, Shape)] = []
    private var eraseLog: [(countAfter: Int, erased: [(Int, Shape)])] = []
    private var eraserHover: Int? { didSet { needsDisplay = true } }

    /// Rotation of a text annotation being re-edited (the editor itself is always upright).
    private var editingRotation: CGFloat = 0
    private var selectedShape: Int? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            if oldValue != selectedShape { syncOptionBars(); layoutToolbar() }
        }
    }
    /// Window frames (view coords, front to back) for click-to-select-window.
    var windowFrames: [CGRect] = []
    private var hoverWindowRect: CGRect?
    /// True while a drag that began by clicking outside an existing selection is in progress.
    private var clickOutsideSelection = false

    var tool: Tool = .move {
        didSet {
            toolbar.selectedTool = tool
            if tool != .move { selectedShape = nil }
            if tool != .eraser { eraserHover = nil }
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
    var shapeFill: Int = Preferences.shapeFill {
        didSet { strokeOptions.fill = shapeFill; Preferences.shapeFill = shapeFill }
    }
    var shapeFillAlpha: CGFloat = Preferences.shapeFillAlpha {
        didSet { strokeOptions.fillAlpha = shapeFillAlpha; Preferences.shapeFillAlpha = shapeFillAlpha }
    }
    var arrowHead: ArrowHead = Preferences.arrowHead {
        didSet { strokeOptions.arrowHead = arrowHead; Preferences.arrowHead = arrowHead }
    }

    private let toolbar = ToolbarView()
    private let palette = ColorPaletteView()
    private let textOptions = TextOptionsView()
    private let strokeOptions = StrokeOptionsView()
    private let mosaicOptions = MosaicOptionsView()
    private lazy var mosaicBackdrop = MosaicBackdrop(screenshot: screenshot, viewSize: bounds.size)
    var mosaicStyle: MosaicStyle = Preferences.mosaicStyle {
        didSet { mosaicOptions.style = mosaicStyle; Preferences.mosaicStyle = mosaicStyle }
    }
    var mosaicLevel: Int = Preferences.mosaicLevel {
        didSet { mosaicOptions.level = mosaicLevel; Preferences.mosaicLevel = mosaicLevel }
    }
    private let emojiOptions = EmojiOptionsView()
    var emoji: String = Preferences.emoji { didSet { emojiOptions.emoji = emoji; Preferences.emoji = emoji; window?.invalidateCursorRects(for: self) } }
    /// Selected user image for the stamp tool (nil = use the emoji).
    var stampImage: String? = Preferences.stampImage {
        didSet { emojiOptions.selectedImage = stampImage; Preferences.stampImage = stampImage; window?.invalidateCursorRects(for: self) }
    }
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
            if self.applyToSelection({ $0.color = c }) { return }   // recolour the selected annotation
            if self.tool == .move { self.tool = .pen }
        }
        addSubview(palette)

        textOptions.isHidden = true
        textOptions.fontSize = textSize
        textOptions.style = textStyle
        textOptions.boxColor = boxColor
        textOptions.boxAlpha = boxAlpha
        textOptions.onSize = { [weak self] v in self?.textSize = v; self?.applyToSelection { if $0.tool == .text || $0.tool == .number { $0.fontSize = v } } }
        textOptions.onStyle = { [weak self] v in self?.textStyle = v; self?.applyToSelection { if $0.tool == .text { $0.textStyle = v } } }
        textOptions.onBoxColor = { [weak self] v in self?.boxColor = v; self?.applyToSelection { if $0.tool == .text { $0.boxColor = v } } }
        textOptions.onBoxAlpha = { [weak self] v in self?.boxAlpha = v; self?.applyToSelection { if $0.tool == .text { $0.boxAlpha = v } } }
        textOptions.onResize = { [weak self] in self?.layoutToolbar() }
        addSubview(textOptions)

        strokeOptions.isHidden = true
        strokeOptions.lineWidth = lineWidth
        strokeOptions.color = color
        strokeOptions.onChange = { [weak self] v in self?.lineWidth = v; self?.applyToSelection { if Self.strokeTools.contains($0.tool) { $0.lineWidth = v } } }
        strokeOptions.dashed = dashed
        strokeOptions.arrowHead = arrowHead
        strokeOptions.onDashed = { [weak self] v in self?.dashed = v; self?.applyToSelection { if Self.strokeTools.contains($0.tool) { $0.dashed = v } } }
        strokeOptions.fill = shapeFill
        strokeOptions.fillAlpha = shapeFillAlpha
        strokeOptions.onFillAlpha = { [weak self] v in self?.shapeFillAlpha = v; self?.applyToSelection { if $0.tool == .rect || $0.tool == .ellipse { $0.fillAlpha = v } } }
        strokeOptions.onFill = { [weak self] v in
            self?.shapeFill = v
            self?.applyToSelection { if $0.tool == .rect || $0.tool == .ellipse { $0.fill = v } }
            self?.layoutToolbar() // the bar grows / shrinks with the opacity slider
        }
        strokeOptions.onArrowHead = { [weak self] v in self?.arrowHead = v; self?.applyToSelection { if $0.tool == .arrow { $0.arrowHead = v } } }
        addSubview(strokeOptions)

        mosaicOptions.isHidden = true
        mosaicOptions.style = mosaicStyle
        mosaicOptions.level = mosaicLevel
        mosaicOptions.onStyle = { [weak self] v in self?.mosaicStyle = v; self?.applyToSelection { if $0.tool == .mosaic { $0.mosaicStyle = v } } }
        mosaicOptions.onLevel = { [weak self] v in self?.mosaicLevel = v; self?.applyToSelection { if $0.tool == .mosaic { $0.mosaicLevel = v } } }
        addSubview(mosaicOptions)

        emojiOptions.isHidden = true
        emojiOptions.emoji = emoji
        emojiOptions.emojiSize = emojiSize
        emojiOptions.recents = Preferences.recentEmojis
        emojiOptions.onPick = { [weak self] e in
            guard let self else { return }
            self.emoji = e
            self.stampImage = nil
            var r = Preferences.recentEmojis.filter { $0 != e }
            r.insert(e, at: 0)
            Preferences.recentEmojis = Array(r.prefix(10))
            self.emojiOptions.recents = Preferences.recentEmojis
            self.layoutToolbar()
        }
        emojiOptions.onSize = { [weak self] size in
            guard let self else { return }
            self.emojiSize = size
            if let i = self.selectedShape, i < self.shapes.count, self.shapes[i].tool == .emoji { self.shapes[i].fontSize = size; self.needsDisplay = true }
        }
        emojiOptions.onStep = { [weak self] in self?.stepStampSize($0) }
        emojiOptions.images = ImageStamps.names
        if let s = stampImage, !ImageStamps.names.contains(s) { stampImage = nil }
        emojiOptions.selectedImage = stampImage
        emojiOptions.onPickImage = { [weak self] in self?.stampImage = $0 }
        emojiOptions.onAddImage = { [weak self] in self?.addStampImageFromFile() }
        emojiOptions.onRemoveImage = { [weak self] name in
            guard let self else { return }
            ImageStamps.remove(name)
            if self.stampImage == name { self.stampImage = nil }
            self.emojiOptions.images = ImageStamps.names
            self.layoutToolbar()
        }
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
        eraseLog = []
        selectedShape = nil
        hoverWindowRect = nil
        currentShape = nil
        drag = .none
        toolbar.isHidden = true
        palette.isHidden = true
        textOptions.isHidden = true
        strokeOptions.isHidden = true
        mosaicOptions.isHidden = true
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
            } else if tool == .eraser {
                addCursorRect(selection, cursor: Self.eraserCursor)
            }
            if tool == .move || tool == .text {
                for r in textShapeRects() { addCursorRect(r.intersection(selection), cursor: .openHand) }
            }
            if let h = stampHandleRect() { addCursorRect(h.insetBy(dx: -4, dy: -4), cursor: .crosshair) }
            for (_, r) in rotateButtonRects() { addCursorRect(r, cursor: .pointingHand) }
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    private var emojiCursorCache: (key: String, cursor: NSCursor)?
    /// A cursor showing the current emoji at (roughly) its stamp size, hotspot in the centre.
    private func emojiCursor() -> NSCursor {
        if let name = stampImage, let img = ImageStamps.image(name) {
            let h = min(max(emojiSize * 1.2, 28), 96)
            let w = min(h * img.size.width / max(img.size.height, 1), 160)
            let key = "img:\(name)@\(w)x\(h)"
            if let c = emojiCursorCache, c.key == key { return c.cursor }
            let cur = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.85)
                NSColor.systemBlue.withAlphaComponent(0.6).setStroke()
                let b = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); b.setLineDash([3, 2], count: 2, phase: 0); b.stroke()
                return true
            }
            let cursor = NSCursor(image: cur, hotSpot: NSPoint(x: w / 2, y: h / 2))
            emojiCursorCache = (key, cursor)
            return cursor
        }
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

    func debugOpenAddImagePanel() {
        selectWholeScreen()
        tool = .emoji
        addStampImageFromFile()
    }

    /// "+ Add" in the stamp bar: pick an image file (PNG with transparency works best for signatures).
    func addStampImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .pdf, .image]
        panel.allowsMultipleSelection = false
        panel.message = L("도장으로 쓸 이미지를 고르세요 (서명·로고 등, 투명 배경 PNG 권장)", "Choose an image to use as a stamp (signature, logo… a transparent PNG works best)")
        panel.prompt = L("추가", "Add")
        // The overlay sits at the shielding level. runModal() resets the panel to the modal-panel level
        // (behind the overlay), so lift it once it is on screen.
        let above = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.level = above
        let lift = Timer(timeInterval: 0.02, repeats: true) { t in
            guard panel.isVisible else { return }
            if panel.level != above { panel.level = above; panel.orderFrontRegardless() }
            if !panel.isVisible || panel.level == above { t.invalidate() }
        }
        RunLoop.main.add(lift, forMode: .modalPanel)
        let result = panel.runModal()
        lift.invalidate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        guard result == .OK, let url = panel.url else { return }
        guard let name = ImageStamps.add(url: url) else {
            NSSound.beep()
            Toast.show(L("이미지를 불러오지 못했습니다", "Couldn't load that image"), subtitle: url.lastPathComponent, duration: 2.0)
            return
        }
        emojiOptions.images = ImageStamps.names
        stampImage = name
        tool = .emoji
        layoutToolbar()
    }

    /// ⌘V during a capture: an image on the clipboard becomes a stamp, placed in the middle of the selection.
    private func pasteImageStamp() -> Bool {
        guard state == .selected,
              let img = NSImage(pasteboard: NSPasteboard.general),
              let name = ImageStamps.add(img) else { return false }
        emojiOptions.images = ImageStamps.names
        stampImage = name
        shapes.append(Shape(tool: .emoji, points: [CGPoint(x: selection.midX, y: selection.midY)], color: color,
                            lineWidth: lineWidth, text: "", fontSize: emojiSize, imageName: name))
        redoStack = []
        tool = .move
        selectedShape = shapes.count - 1
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        return true
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
        guard state == .selected else { toolbar.isHidden = true; palette.isHidden = true; textOptions.isHidden = true; strokeOptions.isHidden = true; emojiOptions.isHidden = true; mosaicOptions.isHidden = true; return }
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
        toolbar.tipsAbove = below
        func place(_ v: NSView) {
            let w = v.frame.width, h = v.frame.height
            let y = below ? nextY - h : nextY
            v.frame = NSRect(x: min(toolbar.frame.minX, bounds.width - w - 4), y: y, width: w, height: h)
            nextY = below ? y - 6 : y + h + 6
        }
        // With an annotation selected, the bars show (and edit) that annotation's settings.
        let ot = optionsTool
        textOptions.isHidden = !(ot == .text || ot == .number)
        if ot == .text || ot == .number { place(textOptions) }
        let drawing = Self.strokeTools
        strokeOptions.isHidden = !drawing.contains(ot)
        strokeOptions.showsDash = [.line, .arrow, .rect, .ellipse].contains(ot)
        strokeOptions.showsHead = ot == .arrow
        strokeOptions.showsFill = ot == .rect || ot == .ellipse
        if drawing.contains(ot) { place(strokeOptions) }
        mosaicOptions.isHidden = ot != .mosaic
        if ot == .mosaic { place(mosaicOptions) }
        emojiOptions.isHidden = tool != .emoji
        if tool == .emoji { place(emojiOptions) }
        if ot != .mosaic { place(palette) } else { palette.isHidden = true }
    }

    static let strokeTools: Set<Tool> = [.pen, .line, .arrow, .rect, .ellipse, .marker]

    /// The selected annotation, when the options bars should edit it (select or text tool).
    private var editableSelection: Int? {
        guard let i = selectedShape, i < shapes.count else { return nil }
        // Select / text tool: whatever is selected. A drawing tool: the shape it just drew.
        guard tool == .move || tool == .text || shapes[i].tool == tool else { return nil }
        return i
    }

    /// Which tool's option bars to show: the selected annotation's kind, otherwise the current tool.
    private var optionsTool: Tool {
        if let i = editableSelection { return shapes[i].tool }
        return tool
    }

    /// Applies a change to the selected annotation. Returns false when nothing is selected.
    @discardableResult
    private func applyToSelection(_ change: (inout Shape) -> Void) -> Bool {
        guard let i = editableSelection else { return false }
        change(&shapes[i])
        needsDisplay = true
        return true
    }

    /// Show the selected annotation's own width / dash / head / colour / text settings in the bars,
    /// or the current defaults when nothing is selected.
    private func syncOptionBars() {
        if let i = editableSelection {
            let sh = shapes[i]
            strokeOptions.lineWidth = sh.lineWidth
            strokeOptions.dashed = sh.dashed
            strokeOptions.arrowHead = sh.arrowHead
            strokeOptions.fill = sh.fill
            strokeOptions.fillAlpha = sh.fillAlpha
            strokeOptions.color = sh.color
            if sh.tool == .text || sh.tool == .number { textOptions.fontSize = sh.fontSize }
            if sh.tool == .text {
                textOptions.style = sh.textStyle
                textOptions.boxColor = sh.boxColor
                textOptions.boxAlpha = sh.boxAlpha
            }
            if sh.tool == .mosaic { mosaicOptions.style = sh.mosaicStyle; mosaicOptions.level = sh.mosaicLevel }
            if sh.tool != .emoji && sh.tool != .mosaic { palette.selected = sh.color; toolbar.currentColor = sh.color }
        } else {
            strokeOptions.lineWidth = lineWidth
            strokeOptions.dashed = dashed
            strokeOptions.arrowHead = arrowHead
            strokeOptions.fill = shapeFill
            strokeOptions.fillAlpha = shapeFillAlpha
            strokeOptions.color = color
            textOptions.fontSize = textSize
            textOptions.style = textStyle
            textOptions.boxColor = boxColor
            textOptions.boxAlpha = boxAlpha
            mosaicOptions.style = mosaicStyle
            mosaicOptions.level = mosaicLevel
            palette.selected = color
            toolbar.currentColor = color
        }
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
        case .ocr:
            extractText()
        case .pin:
            pinSelection()
        case .beautify:
            Beautify.isOn.toggle()
            toolbar.beautifyOn = Beautify.isOn
            Toast.show(Beautify.isOn ? L("꾸미기 켜짐 · 복사·저장·공유에 적용", "Beautify on · applies to copy, save, share")
                                     : L("꾸미기 꺼짐", "Beautify off"), duration: 1.2)
        case .close:
            session?.cancel()
        }
    }

    // MARK: share

    private func showShareMenu() {
        guard state == .selected else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let targets = ShareTarget.available
        for target in targets {
            let title = target.isInstalled ? L("\(target.name)(으)로 보내기", "Send to \(target.name)")
                                           : L("\(target.name)(으)로 보내기 (웹)", "Send to \(target.name) (web)")
            let item = NSMenuItem(title: title, action: #selector(shareToApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = target.name
            if let icon = target.appURL.map({ NSWorkspace.shared.icon(forFile: $0.path) }) {
                icon.size = NSSize(width: 18, height: 18)
                item.image = icon
            } else if let sym = NSImage(systemSymbolName: target.symbol, accessibilityDescription: target.name) {
                item.image = sym
            }
            menu.addItem(item)
        }
        if !targets.isEmpty { menu.addItem(.separator()) }
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
        guard let image = renderResult(), let win = window else { return }
        let anchor = toolbar.rect(for: .share) ?? toolbar.bounds
        let screenRect = win.convertToScreen(toolbar.convert(anchor, to: nil))
        session?.showSystemShareSheet(for: image, at: screenRect)
    }

    /// Edit-menu actions (⌘Z / ⌘C) reach us here when a main menu exists; same behaviour as the key shortcuts.
    @objc func undo(_ sender: Any?) { undoLast() }
    @objc func copy(_ sender: Any?) { if state == .selected { copyToClipboard() } }

    func undoLast() {
        if textEditor != nil { cancelText(); return }
        if let last = eraseLog.last, last.countAfter == shapes.count {
            eraseLog.removeLast()
            for (i, sh) in last.erased.reversed() { shapes.insert(sh, at: min(i, shapes.count)) }
            selectedShape = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
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

        // ↺ / ↻ / 0° buttons next to the selected text or stamp.
        if let hit = rotateButtonRects().first(where: { $0.1.contains(p) }) {
            rotateSelected(hit.0)
            return
        }

        // Corner handle of the selected stamp: drag to resize it.
        if let h = stampHandleRect(), h.insetBy(dx: -4, dy: -4).contains(p), let i = selectedShape, let c = shapes[i].points.first {
            drag = .scaleShape(i, startSize: shapes[i].fontSize, center: c, startDist: max(hypot(p.x - c.x, p.y - c.y), 1))
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
        // With a stamp tool, pressing on an existing stamp grabs it (drag to move) instead of stamping on top.
        if state == .selected, tool == .emoji || tool == .number,
           let i = shapes.indices.reversed().first(where: { (shapes[$0].tool == .emoji || shapes[$0].tool == .number) && shapes[$0].hitTest(p) }) {
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
                if tool == .eraser {
                    eraseGesture = []
                    erase(at: p)
                    drag = .erase
                    return
                }
                if tool == .emoji {
                    shapes.append(Shape(tool: .emoji, points: [p], color: color, lineWidth: lineWidth,
                                        text: stampImage == nil ? emoji : "", fontSize: emojiSize, imageName: stampImage))
                    redoStack = []
                    // A photo / signature is usually placed once and then moved, resized or rotated:
                    // switch to the select tool. ⌥-click keeps the image loaded to stamp it again.
                    if stampImage != nil, !event.modifierFlags.contains(.option) { tool = .move }
                    selectedShape = shapes.count - 1 // shows the resize handle; ⌘+/⌘− resize it
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    return
                }
                if tool == .number {
                    let next = (shapes.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
                    shapes.append(Shape(tool: .number, points: [p], color: color, lineWidth: lineWidth,
                                        text: "\(next)", fontSize: textSize))
                    redoStack = []
                    selectedShape = shapes.count - 1
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                    return
                }
                currentShape = Shape(tool: tool, points: [p, p], color: color, lineWidth: lineWidth, dashed: dashed, arrowHead: arrowHead)
                if tool == .mosaic { currentShape?.mosaicStyle = mosaicStyle; currentShape?.mosaicLevel = mosaicLevel }
                if tool == .rect || tool == .ellipse { currentShape?.fill = shapeFill; currentShape?.fillAlpha = shapeFillAlpha }
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
        case .scaleShape(let i, let startSize, let c, let d0):
            guard i < shapes.count else { return }
            shapes[i].fontSize = min(max(startSize * hypot(p.x - c.x, p.y - c.y) / d0, 8), 400)
        case .erase:
            erase(at: p)
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
            if let s = currentShape, !(s.tool == .mosaic && (s.rect.width < 3 || s.rect.height < 3)) {
                shapes.append(s); redoStack = []
                // Keep the new shape "current": width / dash / colour changes right after drawing apply to it.
                selectedShape = shapes.count - 1
            }
            currentShape = nil
        case .erase:
            if !eraseGesture.isEmpty { eraseLog.append((countAfter: shapes.count, erased: eraseGesture)) }
            eraseGesture = []
        case .moveShape:
            NSCursor.pop()
        case .scaleShape(let i, _, _, _):
            if i < shapes.count, shapes[i].tool == .emoji { emojiSize = shapes[i].fontSize.rounded() } // next stamp keeps this size
        case .none:
            break
        }
        drag = .none
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if state == .selected, tool == .eraser {
            let p = convert(event.locationInWindow, from: nil)
            let i = shapes.indices.reversed().first { shapes[$0].hitTest(p, tolerance: 10) }
            if i != eraserHover { eraserHover = i; needsDisplay = true }
            return
        }
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
        if state == .selected, textEditor == nil {
            if Settings.shortcut(.ocr).matches(event) { extractText(); return }
            if Settings.shortcut(.pin).matches(event) { pinSelection(); return }
            if Settings.shortcut(.mosaic).matches(event) { tool = tool == .mosaic ? .move : .mosaic; return }
        }
        if flags.contains(.command) {
            switch code {
            case 8:  if state == .selected { copyToClipboard() }                       // C
            case 1:  if state == .selected { flags.contains(.shift) ? showShareMenu() : saveToFile() } // S
            case 6:  flags.contains(.shift) ? redoLast() : undoLast()                  // Z / ⇧Z
            case 0:  selectWholeScreen()                                               // A
            case 9:  _ = pasteImageStamp()                                             // V
            case 33: rotateSelected(-1)                                                // [  (counter-clockwise)
            case 30: rotateSelected(1)                                                 // ]  (clockwise)
            case 24, 69: if isStamp(selectedShape) || tool == .emoji { stepStampSize(+1) } else if tool == .text || tool == .number { stepTextSize(+1) } // = / keypad +
            case 27, 78: if isStamp(selectedShape) || tool == .emoji { stepStampSize(-1) } else if tool == .text || tool == .number { stepTextSize(-1) } // - / keypad -
            default: break
            }
            return
        }
        guard state == .selected, flags.isEmpty || flags == .shift else { return }
        let map: [Int: Tool] = [35: .pen, 37: .line, 0: .arrow, 15: .rect, 14: .ellipse, 46: .marker, 17: .text, 45: .number, 1: .emoji, 7: .eraser, 9: .move]
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

    private func isStamp(_ i: Int?) -> Bool {
        guard let i, i < shapes.count else { return false }
        return shapes[i].tool == .emoji || shapes[i].tool == .number
    }

    /// ⌘+/⌘− and the stamp bar's −/＋: resize the selected stamp, or the size of the next one.
    func stepStampSize(_ dir: Int) {
        let f: CGFloat = dir > 0 ? 1.15 : 1 / 1.15
        if let i = selectedShape, isStamp(i) {
            shapes[i].fontSize = min(max(shapes[i].fontSize * f, 8), 400)
            if shapes[i].tool == .emoji { emojiSize = shapes[i].fontSize.rounded() }
        } else {
            emojiSize = min(max(emojiSize * f, 12), 300).rounded()
        }
        needsDisplay = true
    }

    // MARK: rotation (text, emoji and image stamps)

    static let rotateStep: CGFloat = .pi / 12 // 15°

    /// dir: -1 = ↺ counter-clockwise, 1 = ↻ clockwise, 0 = reset.
    func rotateSelected(_ dir: Int) {
        guard let i = selectedShape, i < shapes.count, shapes[i].isRotatable else { return }
        if dir == 0 { shapes[i].rotation = 0 }
        else {
            var r = shapes[i].rotation + (dir < 0 ? Self.rotateStep : -Self.rotateStep)
            r = (r / Self.rotateStep).rounded() * Self.rotateStep
            if abs(r) >= 2 * .pi - 0.001 { r = 0 }
            shapes[i].rotation = abs(r) < 0.001 ? 0 : r
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Rotate bar for the selected text/stamp: ↺, ↻ and (when rotated) "30° ✕" to straighten it.
    /// It is placed on whichever side of the object has the most room, outside the circle the object
    /// sweeps while rotating, and depends only on the unrotated geometry — so it stays put while you
    /// click ↺/↻ repeatedly. The reset slot is reserved even when hidden so nothing shifts.
    private func rotateButtonRects() -> [(Int, CGRect)] {
        guard state == .selected, textEditor == nil, drag.isIdle, let i = selectedShape, i < shapes.count, shapes[i].isRotatable else { return [] }
        let ub = shapes[i].unrotatedBounds
        let c = shapes[i].pivot
        let reach = hypot(ub.width, ub.height) / 2 + 8
        let btn: CGFloat = 26, resetW: CGFloat = 54, gap: CGFloat = 2, pad: CGFloat = 4
        let room = [("top", bounds.height - (c.y + reach)), ("bottom", c.y - reach),
                    ("left", c.x - reach), ("right", bounds.width - (c.x + reach))]
        let side = room.max(by: { $0.1 < $1.1 })!.0
        var rects: [(Int, CGRect)] = []
        if side == "top" || side == "bottom" {
            let w = btn * 2 + resetW + gap * 2
            var x = c.x - w / 2
            x = min(max(x, pad), bounds.width - w - pad)
            var y = side == "top" ? c.y + reach : c.y - reach - btn
            y = min(max(y, pad), bounds.height - btn - pad)
            rects = [(-1, CGRect(x: x, y: y, width: btn, height: btn)),
                     (1, CGRect(x: x + btn + gap, y: y, width: btn, height: btn)),
                     (0, CGRect(x: x + (btn + gap) * 2, y: y, width: resetW, height: btn))]
        } else {
            let h = btn * 3 + gap * 2
            var y = c.y + h / 2 - btn   // top slot
            y = min(max(y, pad + btn * 2 + gap * 2), bounds.height - btn - pad)
            var x = side == "right" ? c.x + reach : c.x - reach - resetW
            x = min(max(x, pad), bounds.width - resetW - pad)
            rects = [(-1, CGRect(x: x, y: y, width: resetW, height: btn)),
                     (1, CGRect(x: x, y: y - btn - gap, width: resetW, height: btn)),
                     (0, CGRect(x: x, y: y - (btn + gap) * 2, width: resetW, height: btn))]
        }
        if shapes[i].rotation == 0 { rects.removeLast() }
        return rects
    }

    private func drawRotateButtons() {
        let rects = rotateButtonRects()
        guard !rects.isEmpty, let i = selectedShape, i < shapes.count else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        func symbol(_ name: String, in r: CGRect) {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
            let tinted = NSImage(size: img.size, flipped: false) { rr in
                img.draw(in: rr); NSColor.white.set(); rr.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        for (id, r) in rects {
            let bg = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
            (id == 0 ? NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 0.95) : NSColor(calibratedWhite: 0.12, alpha: 0.92)).setFill()
            bg.fill()
            NSColor.white.withAlphaComponent(0.22).setStroke(); bg.lineWidth = 1; bg.stroke()
            if id == 0 {
                var deg = Int((-shapes[i].rotation * 180 / .pi).rounded()) % 360
                if deg > 180 { deg -= 360 } else if deg <= -180 { deg += 360 }
                let str = NSAttributedString(string: "\(deg)° ✕", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
                str.draw(at: NSPoint(x: r.midX - str.size().width / 2, y: r.midY - str.size().height / 2))
            } else {
                symbol(id < 0 ? "rotate.left" : "rotate.right", in: r)
            }
        }
    }

    // MARK: eraser

    private func erase(at p: CGPoint) {
        guard let i = shapes.indices.reversed().first(where: { shapes[$0].hitTest(p, tolerance: 10) }) else { return }
        eraseGesture.append((i, shapes.remove(at: i)))
        selectedShape = nil
        eraserHover = nil
        redoStack = []
        needsDisplay = true
    }

    static let eraserCursor: NSCursor = {
        let side: CGFloat = 26
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.set()
            if let sym = symbolImage("eraser.fill", color: .white, pointSize: 17, weight: .semibold) {
                sym.draw(in: NSRect(x: (side - sym.size.width) / 2, y: (side - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
            }
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 7, y: side - 7))
    }()

    /// Small square at the bottom-right of the selected stamp; dragging it scales the stamp.
    private func stampHandleRect() -> CGRect? {
        guard state == .selected, let i = selectedShape, isStamp(i) else { return nil }
        let b = shapes[i].bounds.insetBy(dx: -3, dy: -3)
        return CGRect(x: b.maxX - 5, y: b.minY - 5, width: 10, height: 10)
    }

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
        editingRotation = sh.rotation
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
            var sh = Shape(tool: .text, points: [origin], color: color, lineWidth: lineWidth,
                           text: text, fontSize: textSize, textStyle: textStyle,
                           boxColor: boxColor, boxAlpha: boxAlpha)
            sh.rotation = editingRotation
            shapes.append(sh)
            redoStack = []
        }
        editingRotation = 0
        tv.removeFromSuperview()
        textEditor = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func cancelText() {
        textEditor?.removeFromSuperview()
        textEditor = nil
        editingRotation = 0
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
        ShapeRenderer.backdrop = mosaicBackdrop
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

        // eraser: outline what a click would remove
        if tool == .eraser, let i = eraserHover, i < shapes.count {
            ctx.saveGState()
            ctx.addPath(shapes[i].outlinePath(inset: -4))
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // highlighted annotation (selection tool; a shape just drawn with a drawing tool is kept current silently)
        if let i = selectedShape, i < shapes.count, !Self.strokeTools.contains(tool) {
            ctx.saveGState()
            ctx.addPath(shapes[i].outlinePath(inset: -3))
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let h = stampHandleRect() {
            let hp = NSBezierPath(roundedRect: h, xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); hp.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke(); hp.lineWidth = 1; hp.stroke()
        }
        drawRotateButtons()

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

    // MARK: text extraction (OCR)

    /// The selection from the original screenshot (no annotations), in pixels.
    private func selectionPixels() -> CGImage? {
        let s = pixelScale
        let pixelRect = CGRect(x: selection.minX * s, y: (bounds.height - selection.maxY) * s,
                               width: selection.width * s, height: selection.height * s).integral
        return screenshot.cropping(to: pixelRect)
    }

    /// Pin the (annotated) selection on screen as a floating window and end the capture.
    func pinSelection() {
        guard state == .selected, let image = renderResult(decorated: false), let win = window else { return }
        let frame = win.convertToScreen(convert(selection, to: nil))
        session?.cancel()
        PinWindow.pin(image, at: frame)
    }

    func extractText() {
        guard state == .selected, selection.width >= 4, selection.height >= 4, let img = selectionPixels() else { return }
        commitText()
        NSCursor.operationNotAllowed.set()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let codes = TextRecognizer.barcodes(img)
            let text = codes.isEmpty ? TextRecognizer.recognize(img) : ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.invalidateCursorRects(for: self)
                if !codes.isEmpty {
                    // A QR code wins: its content is usually what you wanted.
                    let payload = codes.joined(separator: "\n")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(payload, forType: .string)
                    self.session?.cancel()
                    let url = codes.first.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
                    Toast.show(url != nil ? L("QR 링크 복사됨 · 클릭하면 열기", "QR link copied · click to open") : L("QR 코드 내용 복사됨", "QR code content copied"),
                               subtitle: codes.first, duration: 2.6, onClick: url.map { u in { NSWorkspace.shared.open(u) } })
                    return
                }
                guard !text.isEmpty else {
                    NSSound.beep()
                    Toast.show(L("글자를 찾지 못했습니다", "No text found"), duration: 1.6)
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self.session?.cancel()
                let first = text.split(separator: "\n").first.map(String.init) ?? text
                Toast.show(L("텍스트 \(text.count)자 복사됨", "Copied \(text.count) characters"), subtitle: first, duration: 2.0)
            }
        }
    }

    /// `decorated`: apply the Beautify export option when it is on (copy / save / share do; pin doesn't).
    func renderResult(decorated: Bool = true) -> NSImage? {
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
        ShapeRenderer.backdrop = mosaicBackdrop
        ShapeRenderer.draw(shapes, in: ctx)
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage() else { return nil }
        if decorated && Beautify.isOn, let pretty = Beautify.apply(to: out, scale: CGFloat(w) / selection.width) {
            return NSImage(cgImage: pretty, size: NSSize(width: CGFloat(pretty.width) * selection.width / CGFloat(w),
                                                         height: CGFloat(pretty.height) * selection.width / CGFloat(w)))
        }
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
        get { ArrowHead(rawValue: UserDefaults.standard.integer(forKey: arrowHeadKey)) ?? .chevron }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: arrowHeadKey) }
    }
    static var shapeFill: Int {
        get { UserDefaults.standard.integer(forKey: "annotationShapeFill") }
        set { UserDefaults.standard.set(newValue, forKey: "annotationShapeFill") }
    }
    static var shapeFillAlpha: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: "annotationShapeFillAlpha"); return v > 0 ? CGFloat(v) : 0.3 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "annotationShapeFillAlpha") }
    }
    static var mosaicStyle: MosaicStyle {
        get { MosaicStyle(rawValue: UserDefaults.standard.integer(forKey: "annotationMosaicStyle")) ?? .pixelate }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "annotationMosaicStyle") }
    }
    static var mosaicLevel: Int {
        get { UserDefaults.standard.object(forKey: "annotationMosaicLevel") == nil ? 1 : UserDefaults.standard.integer(forKey: "annotationMosaicLevel") }
        set { UserDefaults.standard.set(newValue, forKey: "annotationMosaicLevel") }
    }
    private static let lineWidthKey = "annotationLineWidth"
    static var lineWidth: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: lineWidthKey); return v > 0 ? CGFloat(v) : 4 }
        set { UserDefaults.standard.set(Double(newValue), forKey: lineWidthKey) }
    }
    private static let stampImageKey = "stampImageSelected"
    static var stampImage: String? {
        get { UserDefaults.standard.string(forKey: stampImageKey) }
        set { UserDefaults.standard.set(newValue, forKey: stampImageKey) }
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
        // The test drives the real UI, which saves tool settings; put the user's settings back afterwards.
        let ud = UserDefaults.standard
        let savedPrefs = ud.dictionaryRepresentation().filter { $0.key.hasPrefix("annotation") || $0.key.hasPrefix("stamp") || $0.key.hasPrefix("text") || $0.key.hasPrefix("recent") }
        defer {
            for (k, _) in ud.dictionaryRepresentation() where (k.hasPrefix("annotation") || k.hasPrefix("stamp") || k.hasPrefix("text") || k.hasPrefix("recent")) && savedPrefs[k] == nil { ud.removeObject(forKey: k) }
            for (k, v) in savedPrefs { ud.set(v, forKey: k) }
        }
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
        dashed = false; arrowHead = .chevron
        tool = .line
        dragFrom(CGPoint(x: 300, y: H - 300), to: CGPoint(x: 450, y: H - 350))
        check("solid line after toggling off", shapes.last?.tool == .line && shapes.last?.dashed == false)
        key(53)
        check("version compare", UpdateChecker.isNewer("1.10.0", than: "1.9.2") && !UpdateChecker.isNewer("1.9.2", than: "1.9.2") && !UpdateChecker.isNewer("1.9.1", than: "1.9.2"))

        // 5c. image stamp (signature): add a generated image, place it, then clean up
        let sig = NSImage(size: NSSize(width: 200, height: 60), flipped: false) { r in
            NSColor.systemBlue.setStroke(); let p = NSBezierPath(); p.move(to: NSPoint(x: 10, y: 20)); p.curve(to: NSPoint(x: 190, y: 40), controlPoint1: NSPoint(x: 60, y: 70), controlPoint2: NSPoint(x: 120, y: -10)); p.lineWidth = 4; p.stroke(); return true
        }
        let stampsBefore = ImageStamps.names.count
        if stampsBefore >= ImageStamps.maxCount { check("image stamp (skipped: user already has max images)", true) }
        else if let name = ImageStamps.add(sig) {
            emojiOptions.images = ImageStamps.names
            check("image stamp saved", ImageStamps.names.first == name && ImageStamps.names.count == min(stampsBefore + 1, ImageStamps.maxCount))
            tool = .emoji
            stampImage = name
            click(CGPoint(x: 300, y: H - 250))
            let placed = shapes.last
            check("image stamp placed", placed?.tool == .emoji && placed?.imageName == name)
            check("placing an image switches to select", tool == .move && selectedShape == shapes.count - 1)
            tool = .emoji
            if let r = placed?.imageRect { check("image stamp keeps aspect", abs(r.width / r.height - 200.0 / 60.0) < 0.05, "\(r)") }
            else { check("image stamp keeps aspect", false, "no rect") }
            emojiOptions.onPick?("👍")
            check("picking an emoji leaves image mode", stampImage == nil)
            emojiOptions.onRemoveImage?(name)
            check("image stamp removed", !ImageStamps.names.contains(name))
            key(53)
        } else { check("image stamp saved", false, "add failed") }

        // 5d. resize + rotate a freshly placed emoji stamp
        tool = .emoji
        click(CGPoint(x: 360, y: H - 300))
        if let i = shapes.indices.last {
            selectedShape = i
            let savedSize = emojiSize
            defer { emojiSize = savedSize }
            let before = shapes[i].fontSize
            stepStampSize(+1)
            check("stamp resize (⌘+)", shapes[i].fontSize > before, "\(before) → \(shapes[i].fontSize)")
            stepStampSize(-1); stepStampSize(-1)
            check("stamp resize (⌘−)", shapes[i].fontSize < before)
        }
        if let i = shapes.indices.last, let c = shapes[i].points.first {
            selectedShape = i
            rotateSelected(1)
            check("rotate stamp ↻ 15°", abs(shapes[i].rotation + .pi / 12) < 0.001, "\(shapes[i].rotation)")
            check("rotated stamp still hit at centre", shapes[i].hitTest(c))
            check("rotate buttons shown (with reset)", rotateButtonRects().count == 3)
            let r1 = rotateButtonRects().first?.1
            rotateSelected(1)
            check("rotate buttons stay put while rotating", rotateButtonRects().first?.1 == r1)
            rotateSelected(0)
            check("rotation reset", shapes[i].rotation == 0)
        }
        key(53)

        // 5e. edit a placed rectangle's width / dash / colour through the option bars
        tool = .rect
        dragFrom(CGPoint(x: 150, y: H - 150), to: CGPoint(x: 260, y: H - 230))
        if let i = shapes.indices.last, shapes[i].tool == .rect {
            tool = .move
            selectedShape = i
            check("selected shape shows stroke bar", !strokeOptions.isHidden)
            let saved = (color, lineWidth, dashed)
            defer { color = saved.0; lineWidth = saved.1; dashed = saved.2 }
            let target = shapes[i].lineWidth == 7 ? CGFloat(2) : 7
            let wasDashed = shapes[i].dashed
            strokeOptions.onChange?(target)
            strokeOptions.onDashed?(!wasDashed)
            palette.onPick?(.systemGreen)
            check("width applies to selected shape", shapes[i].lineWidth == target)
            check("dash applies to selected shape", shapes[i].dashed != wasDashed)
            check("colour applies to selected shape (tool stays select)", shapes[i].color == .systemGreen && tool == .move)
        } else { check("rect for option-bar test", false) }
        selectedShape = nil

        // 5f. just-drawn shape takes width changes; eraser removes, ⌘Z restores
        do {
            let saved = (color, lineWidth, dashed)
            defer { color = saved.0; lineWidth = saved.1; dashed = saved.2 }
            tool = .line
            dragFrom(CGPoint(x: 120, y: H - 400), to: CGPoint(x: 300, y: H - 400))
            let li = shapes.count - 1
            let target = shapes[li].lineWidth == 7 ? CGFloat(2) : 7
            strokeOptions.onChange?(target)
            check("width applies to the line just drawn", shapes[li].lineWidth == target)
            tool = .eraser
            let n = shapes.count
            click(CGPoint(x: 210, y: H - 400))
            check("eraser removes the line", shapes.count == n - 1)
            undoLast()
            check("⌘Z brings the erased line back", shapes.count == n && shapes[li].tool == .line)
            erase(at: CGPoint(x: 3, y: 3)) // empty spot: nothing to erase
            check("eraser on empty spot does nothing", shapes.count == n)
            tool = .move
        }

        // 5f2. rectangle fill: translucent fill applies and makes the inside clickable
        do {
            let saved = shapeFill
            defer { shapeFill = saved }
            tool = .rect
            dragFrom(CGPoint(x: 140, y: H - 382), to: CGPoint(x: 240, y: H - 418))
            if let i = shapes.indices.last, shapes[i].tool == .rect {
                check("fill picker shown for rectangles", !strokeOptions.isHidden && strokeOptions.showsFill)
                check("inside of an unfilled rect is not the shape", !shapes[i].hitTest(CGPoint(x: 190, y: H - 392)))
                strokeOptions.onFill?(1)
                check("fill applies to the rect just drawn", shapes[i].fill == 1)
                check("filled rect is hit inside", shapes[i].hitTest(CGPoint(x: 190, y: H - 392)))
                let savedA = shapeFillAlpha
                strokeOptions.onFillAlpha?(0.8)
                check("fill opacity applies", abs(shapes[i].fillAlpha - 0.8) < 0.001)
                shapeFillAlpha = savedA
            } else { check("rect for fill test", false, "sel=\(selection) state=\(state)") }
            tool = .move
        }

        // 5g. mosaic: shortcut, drawing, options, and the effect itself on a synthetic image
        do {
            let saved = (mosaicStyle, mosaicLevel)
            defer { mosaicStyle = saved.0; mosaicLevel = saved.1 }
            tool = .move
            key(11) // B (default shortcut)
            check("mosaic shortcut selects the tool", tool == .mosaic)
            let n = shapes.count
            dragFrom(CGPoint(x: 130, y: H - 140), to: CGPoint(x: 260, y: H - 200))
            check("mosaic area added", shapes.count == n + 1 && shapes.last?.tool == .mosaic)
            if let i = shapes.indices.last, shapes[i].tool == .mosaic {
                check("mosaic bar shown", !mosaicOptions.isHidden)
                mosaicOptions.onStyle?(.blur); mosaicOptions.onLevel?(2)
                check("mosaic options apply to the area just drawn", shapes[i].mosaicStyle == .blur && shapes[i].mosaicLevel == 2)
            }
            dragFrom(CGPoint(x: 300, y: H - 140), to: CGPoint(x: 301, y: H - 141))
            check("tiny mosaic drag is ignored", shapes.count == n + 1)
            check("render with mosaic works", renderResult() != nil)
            // synthetic stripes: 1-px alternating columns
            let w = 120, h = 80
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                for x in 0..<w { c.setFillColor(x % 2 == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: x, y: 0, width: 1, height: h)) }
                if let src = c.makeImage() {
                    let bd = MosaicBackdrop(screenshot: src, viewSize: CGSize(width: w, height: h))
                    func px(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
                        var buf = [UInt8](repeating: 0, count: 4)
                        let cc = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        cc.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
                        return buf
                    }
                    if let m = bd.image(for: CGRect(x: 10, y: 10, width: 80, height: 50), style: .pixelate, level: 1) {
                        check("pixelate makes neighbours equal", px(m, 2, 2) == px(m, 3, 2), "\(px(m, 2, 2)) vs \(px(m, 3, 2))")
                    } else { check("pixelate image", false) }
                    if let b = bd.image(for: CGRect(x: 10, y: 10, width: 80, height: 50), style: .blur, level: 1) {
                        let a = px(b, 20, 20), d = px(b, 21, 20)
                        check("blur mixes the stripes", abs(Int(a[0]) - Int(d[0])) < 60 && a[0] > 40 && a[2] > 40, "\(a) \(d)")
                    } else { check("blur image", false) }
                }
            }
            tool = .move
        }

        // 5h. OCR on a rendered sample
        do {
            let sample = NSImage(size: NSSize(width: 520, height: 120), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                NSAttributedString(string: "ShotPark 테스트 123", attributes: [.font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black])
                    .draw(at: NSPoint(x: 20, y: 35))
                return true
            }
            if let cg = sample.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let t = TextRecognizer.recognize(cg)
                check("OCR reads English + digits", t.contains("ShotPark") && t.contains("123"), t)
                check("OCR reads Korean", t.contains("테스트"), t)
            }
            key(8, flags: [.command, .shift]) // ⌘⇧C must not copy the image
            check("⌘⇧C does not end the capture as an image copy", state == .selected)
        }

        // 5j. beautify adds padding at the same pixel scale, keeps the capture inside
        do {
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            if let c = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
                if let src = c.makeImage(), let out = Beautify.apply(to: src, scale: 2, shadow: true, rounded: true) {
                    check("beautify size = image + 2×10pt margin", out.width == 200 + 40 && out.height == 100 + 40, "\(out.width)x\(out.height)")
                    let none = Beautify.apply(to: src, scale: 2, shadow: false, rounded: true)
                    check("no shadow adds no margin", none?.width == 200 && none?.height == 100)
                } else { check("beautify output", false) }
            }
        }

        // 5l. toolbar tooltips are drawn inside the overlay
        do {
            toolbar.debugHover(0)
            check("toolbar tooltip shows", toolbar.visibleTip?.isEmpty == false, toolbar.visibleTip ?? "nil")
            toolbar.hideTip()
            check("toolbar tooltip hides", toolbar.visibleTip == nil)
        }

        // 5i. QR detection on a generated code
        do {
            let f = CIFilter(name: "CIQRCodeGenerator")!
            f.setValue("https://shotpark.site/".data(using: .utf8), forKey: "inputMessage")
            if let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
               let cg = CIContext().createCGImage(ci.clampedToExtent().cropped(to: ci.extent.insetBy(dx: -40, dy: -40)), from: ci.extent.insetBy(dx: -40, dy: -40)) {
                let codes = TextRecognizer.barcodes(cg)
                check("QR code is read", codes.first == "https://shotpark.site/", "\(codes)")
            } else { check("QR test image", false) }
        }

        // 6. click outside with annotations → idle and annotations cleared
        click(CGPoint(x: 20, y: 20))
        check("click outside clears selection + shapes", state == .idle && shapes.isEmpty)

        // 7. stepped Esc from a fresh selection: idle → (session cancel is not exercised here)
        dragFrom(CGPoint(x: 100, y: H - 100), to: CGPoint(x: 300, y: H - 200))
        key(53)
        check("Esc on selection → idle", state == .idle)
        // 8. pin window (last: it ends the capture)
        dragFrom(CGPoint(x: 100, y: H - 100), to: CGPoint(x: 300, y: H - 200))
        let pinsBefore = PinWindow.count
        pinSelection()
        check("pin creates a floating window", PinWindow.count == pinsBefore + 1)
        PinWindow.closeAll()
        check("pins close", PinWindow.count == 0)
        return out
    }
}
