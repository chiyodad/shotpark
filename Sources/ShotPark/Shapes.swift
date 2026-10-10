import AppKit

enum Tool: Int, CaseIterable {
    case move, pen, line, arrow, rect, ellipse, marker, text
}

/// How annotation text is set off from the background.
enum TextStyle: Int, CaseIterable {
    case shadow, outline, plain

    var label: String {
        switch self {
        case .shadow: return "그림자"
        case .outline: return "외곽선"
        case .plain: return "없음"
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
    var textStyle: TextStyle = .shadow

    var rect: CGRect {
        guard points.count >= 2 else { return .zero }
        let a = points[0], b = points[1]
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat, style: TextStyle = .shadow) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: color,
        ]
        switch style {
        case .shadow:
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = max(2, fontSize * 0.1)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, fontSize * 0.05))
            attrs[.shadow] = shadow
        case .outline:
            // Negative stroke width = fill + stroke. Contrast the outline against the text colour.
            let light = (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.6
            attrs[.strokeColor] = light ? NSColor.black : NSColor.white
            attrs[.strokeWidth] = -max(2.5, fontSize * 0.12)
        case .plain:
            break
        }
        return attrs
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
            let size = str.size()
            // `origin` is the top-left corner of the text box.
            str.draw(at: CGPoint(x: origin.x, y: origin.y - size.height))
        }
    }
}
