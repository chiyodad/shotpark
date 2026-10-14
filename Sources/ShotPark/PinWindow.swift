import AppKit

/// A captured image pinned on screen: borderless, always on top, draggable.
/// Scroll to resize, double-click / Esc to close, right-click for copy / save / opacity.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    private let image: NSImage
    private let imageView = PinImageView()
    private var scale: CGFloat = 1

    static var count: Int { open.count }

    /// `frameOnScreen`: where the capture was, so the pin appears exactly over it.
    @discardableResult
    static func pin(_ image: NSImage, at frameOnScreen: NSRect) -> PinWindow {
        let w = PinWindow(image: image, frame: frameOnScreen)
        open.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        return w
    }

    static func closeAll() { open.forEach { $0.close() } }

    private init(image: NSImage, frame: NSRect) {
        self.image = image
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        imageView.autoresizingMask = [.width, .height]
        imageView.owner = self
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        PinWindow.open.removeAll { $0 === self }
        super.close()
    }

    func zoom(by factor: CGFloat) {
        let newScale = min(max(scale * factor, 0.2), 4)
        guard newScale != scale else { return }
        scale = newScale
        var f = frame
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        f.origin.x += (f.width - size.width) / 2
        f.origin.y += (f.height - size.height) / 2
        f.size = size
        setFrame(f, display: true)
    }

    @objc func copyImage() {
        Exporter.copy(image)
        Toast.show(L("클립보드에 복사됨", "Copied to clipboard"), duration: 1.0)
    }
    @objc func saveImage() { Exporter.save(image) }
    @objc func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc func closePin() { close() }
    /// Window ▸ Close (⌘W) reaches a borderless window here and would only beep.
    override func performClose(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close(); return }                                   // esc
        if event.modifierFlags.contains(.command) && event.keyCode == 8 { copyImage(); return } // ⌘C
        if event.modifierFlags.contains(.command) && event.keyCode == 13 { close(); return }    // ⌘W
        super.keyDown(with: event)
    }
}

private final class PinImageView: NSView {
    var image: NSImage?
    weak var owner: PinWindow?

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let b = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1; b.stroke()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.close(); return }
        window?.performDrag(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 10
        guard d != 0 else { return }
        owner?.zoom(by: 1 + max(min(d, 0.3), -0.3))
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let m = NSMenu()
        func item(_ t: String, _ s: Selector, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = owner; i.tag = tag; return i
        }
        m.addItem(item(L("복사", "Copy"), #selector(PinWindow.copyImage)))
        m.addItem(item(L("저장…", "Save…"), #selector(PinWindow.saveImage)))
        let op = NSMenuItem(title: L("투명도", "Opacity"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 75, 50, 30] {
            let i = item("\(v)%", #selector(PinWindow.setOpacity(_:)), tag: v)
            i.state = Int((owner.alphaValue * 100).rounded()) == v ? .on : .off
            sub.addItem(i)
        }
        op.submenu = sub
        m.addItem(op)
        m.addItem(.separator())
        m.addItem(item(L("닫기", "Close"), #selector(PinWindow.closePin)))
        return m
    }
}
