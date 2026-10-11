import AppKit

enum ToolbarAction {
    case selectTool(Tool)
    case color
    case undo
    case copy
    case save
    case share
    case close
}

func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    let configured = base.withSymbolConfiguration(cfg) ?? base
    let size = configured.size
    let img = NSImage(size: size, flipped: false) { rect in
        configured.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    return img
}

/// Multi-line, auto-sizing, transparent text editor used for the text annotation while typing.
final class AnnotationTextView: NSTextView {
    private let ownedStorage: NSTextStorage   // TextKit 1 does not retain the storage for us

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        ownedStorage = storage
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(containerSize: NSSize(width: 4000, height: 4000))
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        lm.addTextContainer(tc)
        super.init(frame: frameRect, textContainer: tc)
        isRichText = false
        drawsBackground = false
        isFieldEditor = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainerInset = .zero
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
}

/// Lightshot-style dark floating toolbar, drawn by hand so it looks the same everywhere.
final class ToolbarView: NSView {
    struct Item {
        let symbol: String
        let tip: String
        let action: ToolbarAction
        var separatorBefore: Bool = false
    }

    static let itemSize: CGFloat = 34
    static let pad: CGFloat = 5
    static let sepWidth: CGFloat = 9
    static let height: CGFloat = 44

    let items: [Item] = [
        Item(symbol: "pencil",               tip: L("펜 (P)", "Pen (P)"),      action: .selectTool(.pen)),
        Item(symbol: "line.diagonal",        tip: L("선 (L)", "Line (L)"),      action: .selectTool(.line)),
        Item(symbol: "arrow.up.right",       tip: L("화살표 (A)", "Arrow (A)"),  action: .selectTool(.arrow)),
        Item(symbol: "rectangle",            tip: L("사각형 (R)", "Rectangle (R)"),  action: .selectTool(.rect)),
        Item(symbol: "circle",               tip: L("타원 (E)", "Ellipse (E)"),    action: .selectTool(.ellipse)),
        Item(symbol: "highlighter",          tip: L("마커 (M)", "Marker (M)"),    action: .selectTool(.marker)),
        Item(symbol: "character",            tip: L("텍스트 (T) — ⇧↩ 줄바꿈, 크기·스타일은 아래 옵션 바", "Text (T) — ⇧↩ new line; size & style in the bar below"), action: .selectTool(.text)),
        Item(symbol: "1.circle",             tip: L("번호 스탬프 (N) — 클릭할 때마다 ①, ②, ③… 순서 표시", "Number stamp (N) — each click places ①, ②, ③…"), action: .selectTool(.number)),
        Item(symbol: "face.smiling",         tip: L("이모지 도장 (S) — 아래에서 이모지를 고르고 클릭해 찍기", "Emoji stamp (S) — pick an emoji below, then click to place"), action: .selectTool(.emoji)),
        Item(symbol: "paintpalette.fill",    tip: L("색상", "Color"),        action: .color),
        Item(symbol: "arrow.uturn.backward", tip: L("실행 취소 (⌘Z)", "Undo (⌘Z)"), action: .undo, separatorBefore: true),
        Item(symbol: "doc.on.doc",           tip: L("클립보드로 복사 (⌘C / Enter)", "Copy to clipboard (⌘C / Enter)"), action: .copy, separatorBefore: true),
        Item(symbol: "square.and.arrow.down", tip: L("저장 (⌘S)", "Save (⌘S)"),  action: .save),
        Item(symbol: "square.and.arrow.up",  tip: L("공유 — Claude · Slack · 카카오톡 (⌘⇧S)", "Share — Claude · Slack · KakaoTalk (⌘⇧S)"), action: .share),
        Item(symbol: "xmark",                tip: L("닫기 (Esc)", "Close (Esc)"),  action: .close),
    ]

    /// Rect of a toolbar item in this view's coordinates (for popping menus below it).
    func rect(for action: ToolbarAction) -> NSRect? {
        guard let i = items.firstIndex(where: { "\($0.action)" == "\(action)" }) else { return nil }
        return itemRects()[i]
    }

    var selectedTool: Tool = .move { didSet { needsDisplay = true } }
    var currentColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var onAction: ((ToolbarAction) -> Void)?

    private var hoverIndex: Int?
    private var pressedIndex: Int?
    private var imageCache: [String: NSImage] = [:]

    override var intrinsicContentSize: NSSize {
        var w = Self.pad * 2
        for it in items {
            if it.separatorBefore { w += Self.sepWidth }
            w += Self.itemSize
        }
        return NSSize(width: w, height: Self.height)
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setFrameSize(intrinsicContentSize)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        rebuildToolTips()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // MARK: layout

    private func itemRects() -> [NSRect] {
        var rects: [NSRect] = []
        var x = Self.pad
        let y = (bounds.height - Self.itemSize) / 2
        for it in items {
            if it.separatorBefore { x += Self.sepWidth }
            rects.append(NSRect(x: x, y: y, width: Self.itemSize, height: Self.itemSize))
            x += Self.itemSize
        }
        return rects
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        tooltipOwners = []
        for (i, r) in itemRects().enumerated() {
            let owner = ToolTipOwner(items[i].tip)
            tooltipOwners.append(owner) // addToolTip does not retain the owner
            addToolTip(r, owner: owner, userData: nil)
        }
    }

    private var tooltipOwners: [ToolTipOwner] = []
    private final class ToolTipOwner: NSObject, NSViewToolTipOwner {
        let text: String
        init(_ t: String) { text = t }
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { text }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    // MARK: drawing

    private func image(for name: String, color: NSColor) -> NSImage? {
        let key = "\(name)|\(color.description)"
        if let c = imageCache[key] { return c }
        let img = symbolImage(name, color: color, pointSize: 15)
        imageCache[key] = img
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let rects = itemRects()
        for (i, it) in items.enumerated() {
            let r = rects[i]
            if it.separatorBefore {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSRect(x: r.minX - Self.sepWidth / 2 - 0.5, y: r.minY + 6, width: 1, height: r.height - 12).fill()
            }

            var isSelected = false
            if case .selectTool(let t) = it.action, t == selectedTool { isSelected = true }

            if isSelected || hoverIndex == i || pressedIndex == i {
                let alpha: CGFloat = pressedIndex == i ? 0.35 : (isSelected ? 0.28 : 0.13)
                NSColor.white.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }

            if case .color = it.action {
                let dot = NSRect(x: r.midX - 8, y: r.midY - 8, width: 16, height: 16)
                currentColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -0.5, dy: -0.5))
                ring.lineWidth = 1.5
                ring.stroke()
            } else if let img = image(for: it.symbol, color: .white) {
                let s = img.size
                let dst = NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height)
                img.draw(in: dst)
            }
        }
    }

    // MARK: events

    private func index(at p: NSPoint) -> Int? {
        itemRects().firstIndex { $0.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressedIndex = index(at: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = index(at: p)
        if let idx, idx == pressedIndex {
            onAction?(items[idx].action)
        }
        pressedIndex = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Small palette that pops below the toolbar when the color button is clicked.
final class ColorPaletteView: NSView {
    /// The user's palette (Settings → 주석 색상). Falls back to `defaultColors`.
    static var colors: [NSColor] { Preferences.palette }
    static let defaultColors: [NSColor] = [
        NSColor(srgbRed: 0.93, green: 0.22, blue: 0.21, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.30, green: 0.69, blue: 0.31, alpha: 1), // green
        NSColor(srgbRed: 0.13, green: 0.59, blue: 0.95, alpha: 1), // blue
        NSColor(srgbRed: 0.61, green: 0.15, blue: 0.69, alpha: 1), // purple
        NSColor(srgbRed: 0.91, green: 0.12, blue: 0.39, alpha: 1), // pink
        NSColor.white,
        NSColor(calibratedWhite: 0.55, alpha: 1),
        NSColor.black,
    ]

    static let swatch: CGFloat = 22
    static let gap: CGFloat = 6
    var onPick: ((NSColor) -> Void)?
    var selected: NSColor?
    private var hoverIndex: Int?

    init() {
        let w = Self.gap + CGFloat(Self.colors.count) * (Self.swatch + Self.gap)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: Self.swatch + Self.gap * 2))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rects() -> [NSRect] {
        (0..<Self.colors.count).map { i in
            NSRect(x: Self.gap + CGFloat(i) * (Self.swatch + Self.gap), y: Self.gap,
                   width: Self.swatch, height: Self.swatch)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.stroke()
        for (i, r) in rects().enumerated() {
            let c = Self.colors[i]
            let inset: CGFloat = hoverIndex == i ? 0 : 2
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: inset, dy: inset)).fill()
            if let selected, selected.isClose(to: c) {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
                ring.lineWidth = 2
                ring.stroke()
            } else {
                NSColor.white.withAlphaComponent(0.35).setStroke()
                NSBezierPath(ovalIn: r.insetBy(dx: inset, dy: inset)).stroke()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = rects().firstIndex { $0.insetBy(dx: -3, dy: -3).contains(p) }
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = rects().firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(p) }) {
            onPick?(Self.colors[idx])
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Options bar shown while the text tool is active: font size (3 presets + free entry),
/// style toggles (shadow / outline / box — any combination), and box colour + opacity.
final class TextOptionsView: NSView, NSTextFieldDelegate {
    static let sizes: [CGFloat] = [16, 24, 40]
    static let height: CGFloat = 34

    var fontSize: CGFloat = 24 { didSet { sizeField.stringValue = "\(Int(fontSize))"; needsDisplay = true } }
    var style: TextStyles = .shadow { didSet { updateLayout(); needsDisplay = true } }
    var boxColor: NSColor = .white { didSet { needsDisplay = true } }
    var boxAlpha: CGFloat = 0.85 { didSet { slider.doubleValue = boxAlpha; needsDisplay = true } }

    var onSize: ((CGFloat) -> Void)?
    var onStyle: ((TextStyles) -> Void)?
    var onBoxColor: ((NSColor) -> Void)?
    var onBoxAlpha: ((CGFloat) -> Void)?
    /// Called whenever the bar's size changes so the host can re-layout.
    var onResize: (() -> Void)?

    private struct Item { let label: String; let width: CGFloat; let size: CGFloat?; let style: TextStyles?; let sepBefore: Bool }
    private var items: [Item] = []
    private var hoverIndex: Int?
    private let slider = NSSlider(value: 0.85, minValue: 0.15, maxValue: 1.0, target: nil, action: nil)
    private let sizeField = NSTextField(string: "24")

    private static let swatch: CGFloat = 18
    private static let swatchGap: CGFloat = 5
    private static let sliderWidth: CGFloat = 90
    private static let sizeFieldWidth: CGFloat = 44

    init() {
        super.init(frame: .zero)
        items = Self.sizes.map { Item(label: "\(Int($0))", width: 36, size: $0, style: nil, sepBefore: false) }
        for (i, st) in TextStyles.all.enumerated() {
            items.append(Item(label: st.label, width: 52, size: nil, style: st, sepBefore: i == 0))
        }

        sizeField.isBezeled = true
        sizeField.bezelStyle = .roundedBezel
        sizeField.controlSize = .small
        sizeField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeField.alignment = .center
        sizeField.focusRingType = .none
        sizeField.delegate = self
        sizeField.toolTip = L("글자 크기 (8–200) 직접 입력 후 Enter", "Type a font size (8–200) and press Enter")
        addSubview(sizeField)

        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isHidden = true
        addSubview(slider)

        updateLayout()
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    // layout: [텍스트] [16][24][40] [field] | [그림자][외곽선][배경] || [배경] swatches slider %
    private let leading: CGFloat = 6 + 44
    private var sizeFieldX: CGFloat { leading + CGFloat(Self.sizes.count) * 36 + 4 }
    private var stylesX: CGFloat { sizeFieldX + Self.sizeFieldWidth + 10 }
    private var baseWidth: CGFloat { stylesX + CGFloat(TextStyles.all.count) * 52 + 6 }
    private var boxSectionX: CGFloat { baseWidth + 4 }

    private func rects() -> [NSRect] {
        var out: [NSRect] = []
        var x = leading
        for it in items {
            if it.sepBefore { x = stylesX }
            out.append(NSRect(x: x, y: 4, width: it.width, height: Self.height - 8))
            x += it.width
        }
        return out
    }

    private func swatchRects() -> [NSRect] {
        let x0 = boxSectionX + 44
        return (0..<Shape.boxColors.count).map { i in
            NSRect(x: x0 + CGFloat(i) * (Self.swatch + Self.swatchGap), y: (Self.height - Self.swatch) / 2,
                   width: Self.swatch, height: Self.swatch)
        }
    }

    private func updateLayout() {
        sizeField.frame = NSRect(x: sizeFieldX, y: (Self.height - 20) / 2, width: Self.sizeFieldWidth, height: 20)
        let showBox = style.contains(.box)
        var w = baseWidth
        if showBox {
            let swatchesW = CGFloat(Shape.boxColors.count) * (Self.swatch + Self.swatchGap)
            let sliderX = boxSectionX + 44 + swatchesW + 10
            slider.frame = NSRect(x: sliderX, y: (Self.height - 16) / 2, width: Self.sliderWidth, height: 16)
            w = sliderX + Self.sliderWidth + 46
        }
        slider.isHidden = !showBox
        let old = frame.size
        setFrameSize(NSSize(width: w, height: Self.height))
        if old != frame.size { onResize?() }
    }

    @objc private func sliderChanged() {
        boxAlpha = CGFloat(slider.doubleValue)
        onBoxAlpha?(boxAlpha)
    }

    // size field: commit on Enter / focus loss
    func controlTextDidEndEditing(_ obj: Notification) {
        if let v = Double(sizeField.stringValue.trimmingCharacters(in: .whitespaces)) {
            let clamped = CGFloat(min(max(v, 8), 200)).rounded()
            fontSize = clamped
            onSize?(clamped)
        } else {
            sizeField.stringValue = "\(Int(fontSize))"
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.stroke()

        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        NSAttributedString(string: L("크기", "Size"), attributes: labelAttrs).draw(at: NSPoint(x: 12, y: (bounds.height - 13) / 2))

        for (i, r) in rects().enumerated() {
            let it = items[i]
            if it.sepBefore {
                NSColor.white.withAlphaComponent(0.18).setFill()
                NSRect(x: r.minX - 5.5, y: r.minY + 4, width: 1, height: r.height - 8).fill()
            }
            let selected = (it.size != nil && it.size == fontSize) || (it.style != nil && style.contains(it.style!))
            if selected || hoverIndex == i {
                NSColor.white.withAlphaComponent(selected ? 0.28 : 0.12).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let font: NSFont = it.size != nil
                ? NSFont.boldSystemFont(ofSize: min(15, 9 + it.size! * 0.14))
                : NSFont.systemFont(ofSize: 12, weight: .medium)
            var text = it.label
            if let st = it.style { text = (style.contains(st) ? "✓ " : "") + text }
            let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            let sz = str.size()
            str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }

        guard style.contains(.box) else { return }
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSRect(x: boxSectionX - 1, y: 8, width: 1, height: bounds.height - 16).fill()
        NSAttributedString(string: L("배경", "Box"), attributes: labelAttrs).draw(at: NSPoint(x: boxSectionX + 8, y: (bounds.height - 13) / 2))
        for (i, r) in swatchRects().enumerated() {
            let c = Shape.boxColors[i]
            c.setFill()
            NSBezierPath(ovalIn: r).fill()
            let isSel = boxColor.isClose(to: c)
            (isSel ? NSColor.white : NSColor.white.withAlphaComponent(0.35)).setStroke()
            let ring = NSBezierPath(ovalIn: isSel ? r.insetBy(dx: -1.5, dy: -1.5) : r)
            ring.lineWidth = isSel ? 2 : 1
            ring.stroke()
        }
        let pct = NSAttributedString(string: "\(Int((boxAlpha * 100).rounded()))%",
                                     attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                  .foregroundColor: NSColor.white])
        pct.draw(at: NSPoint(x: slider.frame.maxX + 6, y: (bounds.height - 13) / 2))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = rects().firstIndex { $0.contains(p) }
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let idx = rects().firstIndex(where: { $0.contains(p) }) {
            let it = items[idx]
            if let sz = it.size { fontSize = sz; onSize?(sz) }
            if let st = it.style {
                if style.contains(st) { style.remove(st) } else { style.insert(st) }
                onStyle?(style)
            }
            return
        }
        if style.contains(.box), let i = swatchRects().firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(p) }) {
            boxColor = Shape.boxColors[i]
            onBoxColor?(boxColor)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Options bar for the emoji stamp: quick picks (recent + presets), size, and the system emoji picker.
final class EmojiOptionsView: NSView, NSTextFieldDelegate {
    static let presets = ["👍", "❤️", "🔥", "✅", "❌", "⭐️", "👀", "💡", "⚠️", "🎉", "😂", "🤔"]
    static let sizes: [CGFloat] = [28, 44, 72]
    static let sizeLabels = [L("작게", "S"), L("보통", "M"), L("크게", "L")]
    static let height: CGFloat = 36

    var emoji: String = "👍" { didSet { needsDisplay = true } }
    var emojiSize: CGFloat = 44 { didSet { needsDisplay = true } }
    var recents: [String] = [] { didSet { rebuildChoices(); needsDisplay = true } }
    var onPick: ((String) -> Void)?
    var onSize: ((CGFloat) -> Void)?
    /// Called when the system picker inserted an emoji (also passed through onPick).
    var onFocusReturn: (() -> Void)?

    private var choices: [String] = []
    var choiceCount: Int { choices.count }
    var firstChoice: String? { choices.first }
    private var hoverIndex: Int?
    private let receiver = NSTextField(string: "")   // hidden target for the Character Viewer
    private let cell: CGFloat = 30
    private let leading: CGFloat = 6 + 40

    init() {
        super.init(frame: .zero)
        receiver.isBezeled = false
        receiver.drawsBackground = false
        receiver.alphaValue = 0.01
        receiver.delegate = self
        addSubview(receiver)
        rebuildChoices()
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rebuildChoices() {
        // Fixed 10 slots: most recently used first, topped up with presets. A newly picked emoji
        // (via "More…") enters at the front and the oldest slot drops off, so the bar never grows.
        var list = recents
        for e in Self.presets where !list.contains(e) { list.append(e) }
        choices = Array(list.prefix(10))
        let w = leading + CGFloat(choices.count) * cell + 12 + 64 + 10 + 3 * 46 + 8
        setFrameSize(NSSize(width: w, height: Self.height))
        receiver.frame = NSRect(x: 2, y: 2, width: 1, height: 1)
    }

    private func choiceRects() -> [NSRect] {
        (0..<choices.count).map { NSRect(x: leading + CGFloat($0) * cell, y: 3, width: cell, height: Self.height - 6) }
    }
    private var moreRect: NSRect { NSRect(x: leading + CGFloat(choices.count) * cell + 12, y: 5, width: 64, height: Self.height - 10) }
    private func sizeRects() -> [NSRect] {
        let x0 = moreRect.maxX + 10
        return (0..<3).map { NSRect(x: x0 + CGFloat($0) * 46, y: 4, width: 46, height: Self.height - 8) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.stroke()
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        NSAttributedString(string: L("도장", "Stamp"), attributes: labelAttrs).draw(at: NSPoint(x: 12, y: (bounds.height - 13) / 2))

        for (i, r) in choiceRects().enumerated() {
            let selected = choices[i] == emoji
            if selected || hoverIndex == i {
                NSColor.white.withAlphaComponent(selected ? 0.28 : 0.12).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let str = NSAttributedString(string: choices[i], attributes: [.font: NSFont.systemFont(ofSize: 18)])
            let sz = str.size()
            str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
        }

        let mr = moreRect
        NSColor.white.withAlphaComponent(hoverIndex == 100 ? 0.2 : 0.1).setFill()
        NSBezierPath(roundedRect: mr, xRadius: 6, yRadius: 6).fill()
        let more = NSAttributedString(string: L("더보기…", "More…"), attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        more.draw(at: NSPoint(x: mr.midX - more.size().width / 2, y: mr.midY - more.size().height / 2))

        for (i, r) in sizeRects().enumerated() {
            let selected = Self.sizes[i] == emojiSize
            if selected || hoverIndex == 200 + i {
                NSColor.white.withAlphaComponent(selected ? 0.28 : 0.12).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let str = NSAttributedString(string: Self.sizeLabels[i], attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
            str.draw(at: NSPoint(x: r.midX - str.size().width / 2, y: r.midY - str.size().height / 2))
        }
    }

    private func index(at p: NSPoint) -> Int? {
        if let i = choiceRects().firstIndex(where: { $0.contains(p) }) { return i }
        if moreRect.contains(p) { return 100 }
        if let i = sizeRects().firstIndex(where: { $0.contains(p) }) { return 200 + i }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let idx = index(at: convert(event.locationInWindow, from: nil))
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard let idx = index(at: convert(event.locationInWindow, from: nil)) else { return }
        if idx < 100 { emoji = choices[idx]; onPick?(emoji) }
        else if idx == 100 {
            // Character Viewer inserts into the first responder → our hidden field
            receiver.stringValue = ""
            window?.makeFirstResponder(receiver)
            NSApp.orderFrontCharacterPalette(nil)
        } else { emojiSize = Self.sizes[idx - 200]; onSize?(emojiSize) }
    }

    func controlTextDidChange(_ obj: Notification) {
        let picked = receiver.stringValue
        guard !picked.isEmpty else { return }
        emoji = picked
        receiver.stringValue = ""
        onPick?(picked)
        onFocusReturn?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Options bar for the drawing tools: stroke width presets.
final class StrokeOptionsView: NSView {
    static let widths: [CGFloat] = [2, 4, 7]
    static let labels = [L("가늘게", "Thin"), L("보통", "Normal"), L("굵게", "Thick")]
    static let height: CGFloat = 34

    var lineWidth: CGFloat = 4 { didSet { needsDisplay = true } }
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    var dashed: Bool = false { didSet { needsDisplay = true } }
    var arrowHead: ArrowHead = .chevron { didSet { needsDisplay = true } }
    /// Which extra controls to show: dash toggle (line/arrow/rect/ellipse) and head picker (arrow only).
    var showsDash: Bool = true { didSet { relayout() } }
    var showsHead: Bool = false { didSet { relayout() } }
    var onChange: ((CGFloat) -> Void)?
    var onDashed: ((Bool) -> Void)?
    var onArrowHead: ((ArrowHead) -> Void)?
    private var hoverIndex: Int?   // 0-2 widths, 10 dash, 20/21 heads

    private let widthsEnd: CGFloat = 50 + 3 * 64
    private var dashRect: NSRect { NSRect(x: widthsEnd + 10, y: 4, width: 58, height: Self.height - 8) }
    private var headLabelX: CGFloat { (showsDash ? dashRect.maxX : widthsEnd) + 10 }
    private func headRects() -> [NSRect] {
        (0..<2).map { NSRect(x: headLabelX + 34 + CGFloat($0) * 40, y: 4, width: 38, height: Self.height - 8) }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 6 + 44 + 3 * 64 + 6, height: Self.height))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 8
        layer?.masksToBounds = false
        relayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func relayout() {
        var w = widthsEnd + 6
        if showsDash { w = dashRect.maxX + 6 }
        if showsHead { w = headRects().last!.maxX + 6 }
        setFrameSize(NSSize(width: w, height: Self.height))
        needsDisplay = true
    }

    private func rects() -> [NSRect] {
        (0..<3).map { NSRect(x: 50 + CGFloat($0) * 64, y: 4, width: 64, height: Self.height - 8) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    private func pill(_ r: NSRect, on: Bool, hover: Bool) {
        if on || hover {
            (on ? NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 1) : NSColor.white.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }
    private func separator(at x: CGFloat) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSRect(x: x, y: 8, width: 1, height: Self.height - 16).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.stroke()
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        let itemAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        NSAttributedString(string: L("굵기", "Width"), attributes: labelAttrs).draw(at: NSPoint(x: 12, y: (bounds.height - 13) / 2))
        for (i, r) in rects().enumerated() {
            let w = Self.widths[i]
            let selected = w == lineWidth
            if selected || hoverIndex == i {
                NSColor.white.withAlphaComponent(selected ? 0.28 : 0.12).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let d = w + 3
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 10, y: r.midY - d / 2, width: d, height: d)).fill()
            let str = NSAttributedString(string: Self.labels[i], attributes: itemAttrs)
            str.draw(at: NSPoint(x: r.minX + 26, y: r.midY - str.size().height / 2))
        }
        if showsDash {
            separator(at: widthsEnd + 4)
            let r = dashRect
            pill(r, on: dashed, hover: hoverIndex == 10)
            // small dashed sample + label
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX + 8, y: r.midY)); path.line(to: NSPoint(x: r.minX + 22, y: r.midY))
            path.lineWidth = 2; path.setLineDash([3, 2], count: 2, phase: 0); NSColor.white.setStroke(); path.stroke()
            let str = NSAttributedString(string: L("점선", "Dash"), attributes: itemAttrs)
            str.draw(at: NSPoint(x: r.minX + 26, y: r.midY - str.size().height / 2))
        }
        if showsHead {
            separator(at: headLabelX - 6)
            NSAttributedString(string: L("머리", "Head"), attributes: labelAttrs).draw(at: NSPoint(x: headLabelX, y: (bounds.height - 13) / 2))
            for (i, r) in headRects().enumerated() {
                let on = arrowHead.rawValue == i
                pill(r, on: on, hover: hoverIndex == 20 + i)
                NSColor.white.setFill()
                if i == 0 {
                    let t = NSBezierPath()
                    t.move(to: NSPoint(x: r.midX - 4, y: r.midY + 7)); t.line(to: NSPoint(x: r.midX + 4, y: r.midY)); t.line(to: NSPoint(x: r.midX - 4, y: r.midY - 7))
                    t.lineWidth = 2.4; t.lineCapStyle = .round; t.lineJoinStyle = .round
                    NSColor.white.setStroke(); t.stroke()
                } else {
                    NSBezierPath(ovalIn: NSRect(x: r.midX - 6, y: r.midY - 6, width: 12, height: 12)).fill()
                }
            }
        }
    }

    private func hit(_ p: NSPoint) -> Int? {
        if let i = rects().firstIndex(where: { $0.contains(p) }) { return i }
        if showsDash, dashRect.contains(p) { return 10 }
        if showsHead, let i = headRects().firstIndex(where: { $0.contains(p) }) { return 20 + i }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let idx = hit(convert(event.locationInWindow, from: nil))
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard let i = hit(convert(event.locationInWindow, from: nil)) else { return }
        switch i {
        case 0...2: lineWidth = Self.widths[i]; onChange?(lineWidth)
        case 10: dashed.toggle(); onDashed?(dashed)
        case 20, 21: arrowHead = ArrowHead(rawValue: i - 20) ?? .chevron; onArrowHead?(arrowHead)
        default: break
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

extension NSColor {
    func isClose(to other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 &&
            abs(a.greenComponent - b.greenComponent) < 0.02 &&
            abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
