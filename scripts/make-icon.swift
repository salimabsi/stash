// Renders the Stash app icon at every size macOS needs and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
// The S curve matches Logo.swift, which draws the same mark for the menu bar.
import AppKit

let coral = NSColor(srgbRed: 1.0, green: 0.36, blue: 0.24, alpha: 1)

/// Drawn on a 1024-point canvas; the body follows Apple's icon grid (824 square, 100 margin).
func drawIcon() {
    let body = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.25)
    drop.shadowOffset = NSSize(width: 0, height: -10)
    drop.shadowBlurRadius = 24
    drop.set()
    coral.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    let radius: CGFloat = 105
    let s = NSBezierPath()
    s.appendArc(withCenter: NSPoint(x: 512, y: 512 + radius), radius: radius, startAngle: 15, endAngle: 270, clockwise: false)
    s.appendArc(withCenter: NSPoint(x: 512, y: 512 - radius), radius: radius, startAngle: 90, endAngle: 195, clockwise: true)
    s.lineWidth = 74
    s.lineCapStyle = .round
    s.lineJoinStyle = .round
    NSColor.white.setStroke()
    s.stroke()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try! png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! png(pixels: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
