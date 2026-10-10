import AppKit

enum Tool: Int, CaseIterable {
    case move, pen, line, arrow, rect, ellipse, marker, text
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
            // Negative stroke width = fill + stroke. Contrast the outline against the text colour
            // (relative luminance, so red counts as dark and gets a white outline).
            let c = color.usingColorSpace(.sRGB) ?? color
            let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            attrs[.strokeColor] = lum > 0.6 ? NSColor.black : NSColor.white
            attrs[.strokeWidth] = -max(2.5, fontSize * 0.12)
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
                ctx.setLineWidth(s.lineWidth * 6)
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
