import AppKit

/// The Stash "S" mark, drawn to match the app icon (scripts/make-icon.swift).
enum Logo {
    /// A template image, so macOS tints it for light and dark menu bars like system icons.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let scale = rect.height * 0.86 / 494
            let radius = 105 * scale
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let s = NSBezierPath()
            s.appendArc(withCenter: NSPoint(x: center.x, y: center.y + radius), radius: radius, startAngle: 15, endAngle: 270, clockwise: false)
            s.appendArc(withCenter: NSPoint(x: center.x, y: center.y - radius), radius: radius, startAngle: 90, endAngle: 195, clockwise: true)
            s.lineWidth = 74 * scale * 1.15
            s.lineCapStyle = .round
            s.lineJoinStyle = .round
            NSColor.black.setStroke()
            s.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Stash"
        return image
    }()
}
