import AppKit

/// "Beautify" export option: a 10 pt margin with a soft shadow and rounded corners
/// (transparent around the image, so it sits nicely on light or dark backgrounds).
enum Beautify {
    static let paddingPoints: CGFloat = 10

    private static let d = UserDefaults.standard
    static var isOn: Bool { get { d.bool(forKey: "beautifyOn") } set { d.set(newValue, forKey: "beautifyOn") } }
    static var shadow: Bool { get { d.object(forKey: "beautifyShadow") == nil ? true : d.bool(forKey: "beautifyShadow") } set { d.set(newValue, forKey: "beautifyShadow") } }
    static var rounded: Bool { get { d.object(forKey: "beautifyRounded") == nil ? true : d.bool(forKey: "beautifyRounded") } set { d.set(newValue, forKey: "beautifyRounded") } }

    /// `image` is in pixels; `scale` = pixels per point. Returns the decorated image (same scale).
    /// The margin is only added when there is a shadow to show in it.
    static func apply(to image: CGImage, scale: CGFloat,
                      shadow: Bool = Beautify.shadow, rounded: Bool = Beautify.rounded) -> CGImage? {
        let pad = shadow ? paddingPoints * scale : 0
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let W = Int((w + pad * 2).rounded()), H = Int((h + pad * 2).rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let radius = rounded ? min(10 * scale, min(w, h) / 4) : 0
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow {
            // Sized to fit inside the 10 pt margin.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 8 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
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
