import AppKit
import CoreImage

enum MosaicStyle: Int { case pixelate = 0, blur = 1 }

/// Produces the mosaic / blur fill for an area, taken from the original screenshot
/// (so annotations drawn on top are never blurred). Results are cached per rect.
final class MosaicBackdrop {
    let screenshot: CGImage
    let viewSize: CGSize           // points
    private var cache: [String: CGImage] = [:]
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(screenshot: CGImage, viewSize: CGSize) {
        self.screenshot = screenshot
        self.viewSize = viewSize
    }

    var scale: CGFloat { CGFloat(screenshot.width) / max(viewSize.width, 1) }

    /// Block size / blur radius in points for strength 0 (light) … 2 (strong).
    static func amount(style: MosaicStyle, level: Int) -> CGFloat {
        let l = min(max(level, 0), 2)
        return style == .pixelate ? [7, 12, 20][l] : [5, 10, 18][l]
    }

    /// Effect image covering `rect` (view points, bottom-left origin), or nil for an empty rect.
    func image(for rect: CGRect, style: MosaicStyle, level: Int) -> CGImage? {
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: viewSize))
        guard r.width >= 1, r.height >= 1 else { return nil }
        let key = "\(Int(r.minX * 2)),\(Int(r.minY * 2)),\(Int(r.width * 2)),\(Int(r.height * 2)),\(style.rawValue),\(level)"
        if let c = cache[key] { return c }
        let s = scale
        // pixel rect in the screenshot (top-left origin)
        let px = CGRect(x: r.minX * s, y: (viewSize.height - r.maxY) * s, width: r.width * s, height: r.height * s).integral
        let amount = Self.amount(style: style, level: level) * s
        let ci = CIImage(cgImage: screenshot)   // CI uses bottom-left origin
        let ciRect = CGRect(x: px.minX, y: CGFloat(screenshot.height) - px.maxY, width: px.width, height: px.height)
        let output: CIImage
        switch style {
        case .pixelate:
            let f = CIFilter(name: "CIPixellate")!
            f.setValue(ci.cropped(to: ciRect).clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(max(2, amount), forKey: kCIInputScaleKey)
            f.setValue(CIVector(x: ciRect.minX, y: ciRect.minY), forKey: kCIInputCenterKey)
            output = f.outputImage!.cropped(to: ciRect)
        case .blur:
            let f = CIFilter(name: "CIGaussianBlur")!
            f.setValue(ci.cropped(to: ciRect).clampedToExtent(), forKey: kCIInputImageKey)
            f.setValue(amount, forKey: kCIInputRadiusKey)
            output = f.outputImage!.cropped(to: ciRect)
        }
        guard let cg = Self.ciContext.createCGImage(output, from: ciRect) else { return nil }
        if cache.count > 40 { cache.removeAll() }
        cache[key] = cg
        return cg
    }
}
