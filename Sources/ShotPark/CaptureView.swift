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
    }

    weak var session: CaptureSession?

    let screenshot: CGImage
    private(set) var state: State = .idle
    private(set) var selection: CGRect = .zero
    private var drag: Drag = .none

    private(set) var shapes: [Shape] = []
    private var currentShape: Shape?

    var tool: Tool = .move {
        didSet {
            toolbar.selectedTool = tool
            layoutToolbar()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = Preferences.color {
        didSet { toolbar.currentColor = color; palette.selected = color; Preferences.color = color; applyTextFieldStyle() }
    }
    var lineWidth: CGFloat = 3

    private let toolbar = ToolbarView()
    private let palette = ColorPaletteView()
    private let textOptions = TextOptionsView()
    private var textField: NSTextField?

    var textSize: CGFloat = Preferences.textSize {
        didSet { textOptions.fontSize = textSize; Preferences.textSize = textSize; applyTextFieldStyle() }
    }
    var textStyle: TextStyle = Preferences.textStyle {
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
        currentShape = nil
        drag = .none
        toolbar.isHidden = true
        palette.isHidden = true
        textOptions.isHidden = true
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

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(bounds)
    }

    private func layoutToolbar() {
        guard state == .selected else { toolbar.isHidden = true; palette.isHidden = true; textOptions.isHidden = true; return }
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
        if !shapes.isEmpty { shapes.removeLast(); needsDisplay = true }
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
                state = .idle
                selection = .zero
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
            if let s = currentShape { shapes.append(s) }
            currentShape = nil
        case .none:
            break
        }
        drag = .none
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if state == .idle { needsDisplay = true }
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

        if code == 53 { // esc
            if textField != nil { cancelText() }
            else if state != .idle { reset() }
            else { session?.cancel() }
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
            case 6:  undoLast()                                                        // Z
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
        let sizes = TextOptionsView.sizes
        guard let i = sizes.firstIndex(of: textSize) else { textSize = sizes[1]; return }
        let j = min(max(i + dir, 0), sizes.count - 1)
        textSize = sizes[j]
    }

    private func beginText(at p: CGPoint) {
        let height = textSize * 1.5
        let width = max(140, selection.maxX - p.x + 4)
        let tf = NSTextField(frame: NSRect(x: p.x - 2, y: p.y - height + textSize * 0.3, width: width, height: height))
        tf.isBezeled = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = self
        tf.lineBreakMode = .byClipping
        addSubview(tf)
        textField = tf
        applyTextFieldStyle()
        window?.makeFirstResponder(tf)
    }

    /// Live-preview the current size / colour / box in the editing field.
    /// While editing, the field is drawn by the shared field editor (an NSTextView), so its
    /// attributes have to be updated too — changing only the NSTextField does nothing visible.
    private func applyTextFieldStyle() {
        guard let tf = textField else { return }
        let font = NSFont.boldSystemFont(ofSize: textSize)
        let bg: NSColor? = textStyle == .box ? boxColor.withAlphaComponent(boxAlpha) : nil

        tf.font = font
        tf.textColor = color
        tf.drawsBackground = bg != nil
        tf.backgroundColor = bg ?? .clear
        tf.placeholderAttributedString = NSAttributedString(string: "텍스트 입력…",
            attributes: [.foregroundColor: color.withAlphaComponent(0.5), .font: font])
        let height = textSize * 1.5
        tf.frame = NSRect(x: tf.frame.minX, y: tf.frame.maxY - height, width: tf.frame.width, height: height)

        if let editor = tf.currentEditor() as? NSTextView {
            editor.font = font
            editor.textColor = color
            editor.insertionPointColor = color
            editor.drawsBackground = bg != nil
            editor.backgroundColor = bg ?? .clear
            editor.typingAttributes = [.font: font, .foregroundColor: color]
            if let storage = editor.textStorage, storage.length > 0 {
                storage.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: storage.length))
            }
            editor.needsDisplay = true
        }
        tf.needsDisplay = true
    }

    private func commitText() {
        guard let tf = textField else { return }
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let origin = CGPoint(x: tf.frame.minX + 2, y: tf.frame.maxY - textSize * 0.2)
            shapes.append(Shape(tool: .text, points: [origin], color: color, lineWidth: lineWidth,
                                text: text, fontSize: textSize, textStyle: textStyle,
                                boxColor: boxColor, boxAlpha: boxAlpha))
        }
        tf.removeFromSuperview()
        textField = nil
        window?.makeFirstResponder(self)
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
            bounds.fill()
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
        ctx.restoreGState()

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
        let str = NSAttributedString(string: "드래그하여 캡처할 영역을 선택하세요  ·  ⌘A 전체 화면  ·  Esc 취소", attributes: [
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
    private static let textStyleKey = "annotationTextStyle"

    static var textSize: CGFloat {
        get { let v = UserDefaults.standard.double(forKey: textSizeKey); return v > 0 ? CGFloat(v) : 20 }
        set { UserDefaults.standard.set(Double(newValue), forKey: textSizeKey) }
    }
    static var textStyle: TextStyle {
        get { TextStyle(rawValue: UserDefaults.standard.integer(forKey: textStyleKey)) ?? .shadow }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: textStyleKey) }
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
