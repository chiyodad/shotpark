import AppKit

enum Tool: Int, CaseIterable {
    case move, pen, line, arrow, rect, ellipse, marker, text, number, emoji
}

/// How annotation text is set off from the background. Any combination can be on at once.
struct TextStyles: OptionSet, Equatable {
    let rawValue: Int
    static let shadow  = TextStyles(rawValue: 1 << 0)
    static let outline = TextStyles(rawValue: 1 << 1)
    static let box     = TextStyles(rawValue: 1 << 2)

    static let all: [TextStyles] = [.shadow, .outline, .box]

    var label: String {
        switch self {
        case .shadow: return "그림자"
        case .outline: return "외곽선"
        case .box: return "배경"
        default: return ""
        }
    }
}

struct Shape {
    var tool: Tool
    var points: [CGPoint]
    var color: NSColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 20
    var textStyle: TextStyles = .shadow
    var boxColor: NSColor = .white
    var boxAlpha: CGFloat = 0.85

    var rect: CGRect {
        guard points.count >= 2 else { return .zero }
        let a = points[0], b = points[1]
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat, style: TextStyles = .shadow) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color,
        ]
        if style.contains(.shadow) {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = max(2, fontSize * 0.1)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize * 0.05))
            attrs[.shadow] = shadow
        }
        if style.contains(.outline) {
            // Thin black outline. NSAttributedString.strokeWidth is a PERCENTAGE of the font size
            // (negative = fill + stroke), so it must not be scaled by the font size again.
            attrs[.strokeColor] = NSColor.black
            attrs[.strokeWidth] = -3.5
        }
        return attrs
    }

    /// Padding of the `.box` background, proportional to the font size.
    static func boxPadding(fontSize: CGFloat) -> CGSize {
        CGSize(width: max(12, (fontSize * 0.55).rounded()), height: max(8, (fontSize * 0.4).rounded()))
    }

    /// Text rectangle for a text shape whose `origin` is the top-left corner of the glyph box.
    static func textRect(text: String, fontSize: CGFloat, style: TextStyles, origin: CGPoint) -> CGRect {
        let attrs = textAttributes(color: .black, fontSize: fontSize, style: style)
        let size = NSAttributedString(string: text.isEmpty ? " " : text, attributes: attrs).size()
        return CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
    }

    /// Background box rectangle (text rect + padding). Used for drawing, live preview and hit-testing.
    static func boxRect(text: String, fontSize: CGFloat, style: TextStyles, origin: CGPoint) -> CGRect {
        let pad = boxPadding(fontSize: fontSize)
        return textRect(text: text, fontSize: fontSize, style: style, origin: origin).insetBy(dx: -pad.width, dy: -pad.height)
    }

    static func boxCornerRadius(fontSize: CGFloat) -> CGFloat { min(10, fontSize * 0.3) }
    static let boxColors: [NSColor] = [
        .white, .black,
        NSColor(srgbRed: 1.00, green: 0.93, blue: 0.35, alpha: 1), // yellow
        NSColor(srgbRed: 0.75, green: 0.95, blue: 0.55, alpha: 1), // lime
        NSColor(srgbRed: 0.70, green: 0.88, blue: 1.00, alpha: 1), // sky
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.86, alpha: 1), // pink
    ]
}

extension Shape {
    /// Stroke width actually used on screen (marker is a wide translucent band).
    var effectiveWidth: CGFloat { tool == .marker ? lineWidth * 5 : lineWidth }

    /// Radius of a number stamp (scales with the text size setting).
    var stampRadius: CGFloat { max(12, fontSize * 0.7) }

    static func emojiAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size)]
    }

    /// Rough bounding box used for selection highlight.
    var bounds: CGRect {
        switch tool {
        case .emoji:
            guard let c = points.first else { return .zero }
            let sz = NSAttributedString(string: text, attributes: Shape.emojiAttributes(size: fontSize)).size()
            return CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
        case .number:
            guard let c = points.first else { return .zero }
            return CGRect(x: c.x - stampRadius, y: c.y - stampRadius, width: stampRadius * 2, height: stampRadius * 2)
        case .text:
            guard let o = points.first else { return .zero }
            return Shape.boxRect(text: text, fontSize: fontSize, style: textStyle, origin: o)
        default:
            guard let f = points.first else { return .zero }
            var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
            for q in points { minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y) }
            let pad = effectiveWidth / 2 + (tool == .arrow ? max(14, lineWidth * 4.5) * 0.6 : 0)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -pad, dy: -pad)
        }
    }

    private static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 0.0001 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// True when `p` is on / very near the drawn marks (so clicks inside an empty rectangle still
    /// start a new shape instead of grabbing the rectangle).
    func hitTest(_ p: CGPoint, tolerance: CGFloat = 7) -> Bool {
        let tol = tolerance + effectiveWidth / 2
        switch tool {
        case .move: return false
        case .text, .emoji: return bounds.contains(p)
        case .number:
            guard let c = points.first else { return false }
            return hypot(p.x - c.x, p.y - c.y) <= stampRadius + 2
        case .rect:
            let r = rect
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        case .ellipse:
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
            let d = sqrt(nx * nx + ny * ny) // 1 == on the ellipse
            let band = tol / max(1, min(r.width, r.height) / 2)
            return abs(d - 1) <= band
        case .line, .arrow:
            guard points.count >= 2 else { return false }
            return Shape.distance(p, toSegment: points[0], points[1]) <= tol
        case .pen, .marker:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= tol }
            for i in 1..<points.count where Shape.distance(p, toSegment: points[i - 1], points[i]) <= tol { return true }
            return false
        }
    }

    func translated(by d: CGPoint) -> Shape {
        var c = self
        c.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return c
    }
}

/// Draws shapes in a non-flipped (bottom-left origin) CoreGraphics context.
/// The same routine is used on screen and when exporting, so output matches preview.
enum ShapeRenderer {
    static func draw(_ shapes: [Shape], in ctx: CGContext) {
        for s in shapes { draw(s, in: ctx) }
    }

    static func draw(_ s: Shape, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        ctx.setLineWidth(s.lineWidth)

        switch s.tool {
        case .move:
            break

        case .pen, .marker:
            guard let first = s.points.first else { return }
            if s.tool == .marker {
                ctx.setLineWidth(s.effectiveWidth)
                ctx.setLineCap(.square)
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(s.color.withAlphaComponent(0.45).cgColor)
            }
            ctx.beginPath()
            ctx.move(to: first)
            if s.points.count == 1 {
                ctx.addLine(to: first)
            } else {
                for p in s.points.dropFirst() { ctx.addLine(to: p) }
            }
            ctx.strokePath()

        case .line:
            guard s.points.count >= 2 else { return }
            ctx.beginPath()
            ctx.move(to: s.points[0])
            ctx.addLine(to: s.points[1])
            ctx.strokePath()

        case .arrow:
            guard s.points.count >= 2 else { return }
            let start = s.points[0], end = s.points[1]
            let dx = end.x - start.x, dy = end.y - start.y
            let len = max(sqrt(dx * dx + dy * dy), 0.001)
            let ux = dx / len, uy = dy / len
            let headLen = max(14, s.lineWidth * 4.5)
            let headWidth = headLen * 0.6
            let base = CGPoint(x: end.x - ux * headLen, y: end.y - uy * headLen)
            let px = -uy * headWidth, py = ux * headWidth
            ctx.beginPath()
            ctx.move(to: start)
            ctx.addLine(to: CGPoint(x: end.x - ux * headLen * 0.6, y: end.y - uy * headLen * 0.6))
            ctx.strokePath()
            ctx.beginPath()
            ctx.move(to: end)
            ctx.addLine(to: CGPoint(x: base.x + px, y: base.y + py))
            ctx.addLine(to: CGPoint(x: base.x - px, y: base.y - py))
            ctx.closePath()
            ctx.fillPath()

        case .rect:
            ctx.stroke(s.rect)

        case .ellipse:
            ctx.strokeEllipse(in: s.rect)

        case .emoji:
            guard let c = s.points.first, !s.text.isEmpty else { return }
            let str = NSAttributedString(string: s.text, attributes: Shape.emojiAttributes(size: s.fontSize))
            let sz = str.size()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            str.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

        case .number:
            guard let c = s.points.first else { return }
            let r = s.stampRadius
            let circle = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(1.5, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
            let str = NSAttributedString(string: s.text, attributes: [
                .font: NSFont.boldSystemFont(ofSize: r * 1.15), .foregroundColor: NSColor.white])
            let sz = str.size()
            str.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))

        case .text:
            guard let origin = s.points.first, !s.text.isEmpty else { return }
            let attrs = Shape.textAttributes(color: s.color, fontSize: s.fontSize, style: s.textStyle)
            let str = NSAttributedString(string: s.text, attributes: attrs)
            // `origin` is the top-left corner of the text box.
            let textOrigin = Shape.textRect(text: s.text, fontSize: s.fontSize, style: s.textStyle, origin: origin).origin
            if s.textStyle.contains(.box) {
                let box = Shape.boxRect(text: s.text, fontSize: s.fontSize, style: s.textStyle, origin: origin)
                ctx.setFillColor(s.boxColor.withAlphaComponent(s.boxAlpha).cgColor)
                let r = Shape.boxCornerRadius(fontSize: s.fontSize)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil))
                ctx.fillPath()
            }
            str.draw(at: textOrigin)
        }
    }
}
