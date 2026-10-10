import AppKit
import ScreenCaptureKit

enum ScreenCapture {
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            ?? CGMainDisplayID()
    }

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Shareable-content cache
    //
    // `SCShareableContent` enumeration is the slow part of a capture (hundreds of ms, it walks every
    // window on the system). We only need the SCDisplay objects, which practically never change, so
    // we fetch them ahead of time and keep them warm. A capture then only pays for the screenshot
    // itself (~tens of ms).

    @available(macOS 14.0, *)
    private static var cachedContent: SCShareableContent?
    private static var cacheDate: Date = .distantPast
    private static let cacheMaxAge: TimeInterval = 120

    /// Fetch display info in the background so the next hotkey press is instant.
    static func prewarm() {
        guard #available(macOS 14.0, *) else { return }
        Task.detached(priority: .utility) {
            await refreshCache()
        }
    }

    @available(macOS 14.0, *)
    @discardableResult
    private static func refreshCache() async -> SCShareableContent? {
        do {
            // onScreenWindowsOnly: true keeps the enumeration as cheap as possible.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run {
                cachedContent = content
                cacheDate = Date()
            }
            return content
        } catch {
            NSLog("SCShareableContent failed: \(error.localizedDescription)")
            return nil
        }
    }

    @available(macOS 14.0, *)
    private static func content() async -> SCShareableContent? {
        let (cached, age) = await MainActor.run { (cachedContent, Date().timeIntervalSince(cacheDate)) }
        if let cached {
            if age > cacheMaxAge { prewarm() } // refresh in background, use the warm one now
            return cached
        }
        return await refreshCache()
    }

    /// Captures a full-resolution image of one display.
    static func capture(displayID: CGDirectDisplayID) async -> CGImage? {
        if #available(macOS 14.0, *) {
            do {
                guard let content = await content(),
                      let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    return legacyCapture(displayID)
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let scale = CGFloat(filter.pointPixelScale)
                let config = SCStreamConfiguration()
                config.width = Int((CGFloat(display.width) * scale).rounded())
                config.height = Int((CGFloat(display.height) * scale).rounded())
                config.showsCursor = false
                config.captureResolution = .best
                config.pixelFormat = kCVPixelFormatType_32BGRA
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                NSLog("SCScreenshotManager failed: \(error.localizedDescription) — falling back")
                return legacyCapture(displayID)
            }
        } else {
            return legacyCapture(displayID)
        }
    }

    /// Captures every screen concurrently, preserving the order of `screens`.
    static func captureAll(_ screens: [NSScreen]) async -> [(NSScreen, CGImage)] {
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, screen) in screens.enumerated() {
                let id = displayID(for: screen)
                group.addTask { (i, await capture(displayID: id)) }
            }
            var results: [(Int, CGImage)] = []
            for await (i, img) in group {
                if let img { results.append((i, img)) }
            }
            return results.sorted { $0.0 < $1.0 }.map { (screens[$0.0], $0.1) }
        }
    }

    private static func legacyCapture(_ displayID: CGDirectDisplayID) -> CGImage? {
        CGDisplayCreateImage(displayID)
    }
}
