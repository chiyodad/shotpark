import AppKit

/// "Beautify" export option: padding on a gradient background, a soft shadow and rounded corners.
enum Beautify {
    static let backgrounds: [(name: String, colors: [NSColor])] = [
        (L("없음 (투명)", "None (transparent)"), []),
        (L("보라", "Violet"), [NSColor(srgbRed: 0.50, green: 0.35, blue: 0.94, alpha: 1), NSColor(srgbRed: 0.17, green: 0.69, blue: 1.00, alpha: 1)]),
        (L("파랑", "Blue"), [NSColor(srgbRed: 0.31, green: 0.55, blue: 1.00, alpha: 1), NSColor(srgbRed: 0.24, green: 0.84, blue: 0.96, alpha: 1)]),
        (L("노을", "Sunset"), [NSColor(srgbRed: 1.00, green: 0.49, blue: 0.37, alpha: 1), NSColor(srgbRed: 1.00, green: 0.71, blue: 0.48, alpha: 1)]),
        (L("민트", "Mint"), [NSColor(srgbRed: 0.26, green: 0.91, blue: 0.48, alpha: 1), NSColor(srgbRed: 0.22, green: 0.98, blue: 0.84, alpha: 1)]),
        (L("회색", "Gray"), [NSColor(srgbRed: 0.88, green: 0.89, blue: 0.92, alpha: 1), NSColor(srgbRed: 0.76, green: 0.78, blue: 0.83, alpha: 1)]),
    ]
    static let paddings: [(name: String, points: CGFloat)] = [(L("작게", "Small"), 24), (L("보통", "Medium"), 48), (L("크게", "Large"), 80)]

    private static let d = UserDefaults.standard
    static var isOn: Bool { get { d.bool(forKey: "beautifyOn") } set { d.set(newValue, forKey: "beautifyOn") } }
    static var background: Int {
        get { d.object(forKey: "beautifyBackground") == nil ? 1 : min(max(d.integer(forKey: "beautifyBackground"), 0), backgrounds.count - 1) }
        set { d.set(newValue, forKey: "beautifyBackground") }
    }
    static var padding: Int {
        get { d.object(forKey: "beautifyPadding") == nil ? 1 : min(max(d.integer(forKey: "beautifyPadding"), 0), paddings.count - 1) }
        set { d.set(newValue, forKey: "beautifyPadding") }
    }
    static var shadow: Bool { get { d.object(forKey: "beautifyShadow") == nil ? true : d.bool(forKey: "beautifyShadow") } set { d.set(newValue, forKey: "beautifyShadow") } }
    static var rounded: Bool { get { d.object(forKey: "beautifyRounded") == nil ? true : d.bool(forKey: "beautifyRounded") } set { d.set(newValue, forKey: "beautifyRounded") } }

    /// `image` is `pixels` big; `scale` = pixels per point. Returns the decorated image (same scale).
    static func apply(to image: CGImage, scale: CGFloat,
                      background bgIndex: Int = Beautify.background, padding padIndex: Int = Beautify.padding,
                      shadow: Bool = Beautify.shadow, rounded: Bool = Beautify.rounded) -> CGImage? {
        let colors = backgrounds[min(max(bgIndex, 0), backgrounds.count - 1)].colors
        let pad = (colors.isEmpty && !shadow) ? 0 : paddings[min(max(padIndex, 0), paddings.count - 1)].points * scale
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let W = Int((w + pad * 2).rounded()), H = Int((h + pad * 2).rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        if colors.count >= 2, let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                                  colors: colors.map(\.cgColor) as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: canvas.maxX, y: 0), options: [])
        }
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let radius = rounded ? min(12 * scale, min(w, h) / 4) : 0
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow && pad > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
