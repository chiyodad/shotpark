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

    /// Captures a full-resolution image of one display.
    static func capture(displayID: CGDirectDisplayID) async -> CGImage? {
        if #available(macOS 14.0, *) {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
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

    private static func legacyCapture(_ displayID: CGDirectDisplayID) -> CGImage? {
        CGDisplayCreateImage(displayID)
    }
}
