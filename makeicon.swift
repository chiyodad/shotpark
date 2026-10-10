// Generates icon.png (1024x1024) — run: swift makeicon.swift
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

let m = S * 0.09, r = S * 0.22
let bg = NSBezierPath(roundedRect: NSRect(x: m, y: m, width: S - 2 * m, height: S - 2 * m), xRadius: r, yRadius: r)
let grad = NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.08, blue: 0.63, alpha: 1),
                      ending: NSColor(srgbRed: 0.35, green: 0.27, blue: 0.86, alpha: 1))!
grad.draw(in: bg, angle: 90)

let w = S * 0.055, L = S * 0.17, a = S * 0.26, b = S - a
NSColor.white.setFill()
let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(a, a, 1, 1), (b, a, -1, 1), (a, b, 1, -1), (b, b, -1, -1)]
for (x, y, dx, dy) in corners {
    let h = NSRect(x: min(x, x + dx * L), y: min(y, y + dy * w), width: L, height: w)
    let v = NSRect(x: min(x, x + dx * w), y: min(y, y + dy * L), width: w, height: L)
    NSBezierPath(roundedRect: h, xRadius: w / 2, yRadius: w / 2).fill()
    NSBezierPath(roundedRect: v, xRadius: w / 2, yRadius: w / 2).fill()
}
let c = S / 2, R = S * 0.11
NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: c - R, y: c - R, width: 2 * R, height: 2 * R)).fill()
NSColor(srgbRed: 1, green: 0.67, blue: 0.67, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: c - R * 0.65, y: c + R * 0.05, width: R * 0.65, height: R * 0.65)).fill()
img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "icon.png"))
print("icon.png written (\(rep.pixelsWide)x\(rep.pixelsHigh))")
