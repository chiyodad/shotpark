import AppKit

/// User images (signatures, logos, stamps) usable with the stamp tool.
/// Stored as PNG copies in ~/Library/Application Support/ShotPark/Stamps, newest first, at most `maxCount`.
enum ImageStamps {
    static let maxCount = 3
    private static let namesKey = "stampImages"
    private static var cache: [String: NSImage] = [:]

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("ShotPark/Stamps", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var names: [String] {
        get {
            var list = (UserDefaults.standard.stringArray(forKey: namesKey) ?? [])
                .filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            if list.count > maxCount { // older versions kept more; drop the oldest
                while list.count > maxCount { remove(list.removeLast(), updatingList: false) }
                UserDefaults.standard.set(list, forKey: namesKey)
            }
            return list
        }
        set { UserDefaults.standard.set(newValue, forKey: namesKey) }
    }

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let i = NSImage(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        cache[name] = i
        return i
    }

    @discardableResult
    static func add(url: URL) -> String? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return add(img)
    }

    /// Saves a downscaled PNG copy (longest side ≤ 800 px, transparency kept) and puts it first.
    @discardableResult
    static func add(_ image: NSImage) -> String? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(src.width), h = CGFloat(src.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, 800 / max(w, h))
        let pw = max(1, Int(w * scale)), ph = max(1, Int(h * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        gc.imageInterpolation = .high
        gc.cgContext.draw(src, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = UUID().uuidString + ".png"
        do { try png.write(to: dir.appendingPathComponent(name)) } catch { return nil }
        var list = names
        list.insert(name, at: 0)
        while list.count > maxCount { remove(list.removeLast(), updatingList: false) }
        names = list
        return name
    }

    static func remove(_ name: String) { remove(name, updatingList: true) }

    private static func remove(_ name: String, updatingList: Bool) {
        // Keep the cached image: annotations already placed in this capture may still use it.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        if updatingList { names = names.filter { $0 != name } }
    }
}
