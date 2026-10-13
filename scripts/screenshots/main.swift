// Renders docs/screenshot.png (the real Stash window, drawn offscreen from sample notes)
// and docs/menus.png (its menus, which briefly appear on screen to be captured).
// Run through scripts/make-screenshots.sh, which points STASH_DATA_DIR at a temporary folder.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let docs = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let windowSize = NSSize(width: 360, height: 620)

let lightNotes = """
# Landing page
- [ ] Ask Claude to tighten the hero copy: **one sentence**, no buzzwords, verb first <!-- orange -->
- [ ] Prompt: review `PricingTable.tsx` for accessibility issues and list the fixes by severity
- [ ] Make the signup card look like this
  ![Signup sketch.png](attachments/a1c2e3f4-Signup sketch.png)
- [x] Compare three headline options in ChatGPT

## Follow-ups
- [ ] Why is the **OG image** blurry in Slack link previews? <!-- red -->
- [ ] Read Apple's [guidance on menu bar extras](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) <!-- blue -->
"""

let darkNotes = """
# Config research
- [ ] **Negation in inherited configs.** Once a config can extend a preset, someone will need to *remove* something the preset added. <!-- purple -->
- [ ] Use **TOML as the default format**, backed by a published JSON schema
- [ ] Prompt: compare TOML, YAML and JSON5 for hand-edited config files, then recommend one
- [x] Skim how Cargo and Biome structure their config docs

## Open questions
- [ ] Should plugins own their config schema? <!-- yellow -->
- [ ] How do migrations work when a key gets renamed?
"""

/// A rough wireframe drawn with the editor's own strokes, used as the sample attachment.
func sketch() -> Data {
    let size = NSSize(width: 640, height: 400)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 800, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let strokes = [
        Stroke(kind: .rectangle(CGRect(x: 150, y: 40, width: 300, height: 320)), color: .ink, width: 3),
        Stroke(kind: .text("Create account", CGPoint(x: 180, y: 66)), color: .ink, width: 0),
        Stroke(kind: .rectangle(CGRect(x: 180, y: 120, width: 240, height: 44)), color: .ink, width: 2),
        Stroke(kind: .rectangle(CGRect(x: 180, y: 180, width: 240, height: 44)), color: .ink, width: 2),
        Stroke(kind: .rectangle(CGRect(x: 180, y: 270, width: 240, height: 54)), color: .blue, width: 3),
        Stroke(kind: .text("Sign up", CGPoint(x: 268, y: 284)), color: .blue, width: 0),
        Stroke(kind: .arrow(CGPoint(x: 580, y: 230), CGPoint(x: 440, y: 290)), color: .red, width: 3),
        Stroke(kind: .text("bigger, blue", CGPoint(x: 480, y: 190)), color: .red, width: 0),
    ]
    NSGraphicsContext.saveGraphicsState()
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: size.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { strokes.forEach { $0.draw() } }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
func renderWindow(notes: String, active: String, dark: Bool) -> NSBitmapImageRep {
    try! notes.write(to: Store.directory.appendingPathComponent("stash.md"), atomically: true, encoding: .utf8)
    UserDefaults.standard.set(active, forKey: "activeSection")
    UserDefaults.standard.set(false, forKey: "showAllSections")
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    let panel = PanelController(store: Store())
    _ = panel.isVisible
    let window = NSApp.windows.last { $0.title == "Stash" }!
    window.appearance = app.appearance
    window.setContentSize(windowSize)
    let view = window.contentView!
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    window.close()
    return rep
}

/// Both windows side by side on a split light/dark backdrop, each with the window's own
/// rounded corners, edge and shadow (the offscreen render is a plain rectangle).
func compose(light: NSBitmapImageRep, dark: NSBitmapImageRep) -> Data {
    let canvas = NSSize(width: 960, height: 760)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: canvas.width / 2, height: canvas.height).fill()
    NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
    NSRect(x: canvas.width / 2, y: 0, width: canvas.width / 2, height: canvas.height).fill()

    let y = (canvas.height - windowSize.height) / 2
    let shots: [(NSBitmapImageRep, CGFloat, NSColor, NSColor)] = [
        (light, canvas.width / 4, NSColor(srgbRed: 0.918, green: 0.918, blue: 0.929, alpha: 1), NSColor(white: 0, alpha: 0.1)),
        (dark, canvas.width * 3 / 4, NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1), NSColor(white: 1, alpha: 0.12)),
    ]
    for (shot, centerX, background, edge) in shots {
        let frame = NSRect(x: centerX - windowSize.width / 2, y: y, width: windowSize.width, height: windowSize.height)
        let body = NSBezierPath(roundedRect: frame, xRadius: 26, yRadius: 26)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.shadowBlurRadius = 44
        shadow.set()
        background.setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        shot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        edge.setStroke()
        body.lineWidth = 1
        body.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let attachments = Store.directory.appendingPathComponent("attachments", isDirectory: true)
    try! FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    try! sketch().write(to: attachments.appendingPathComponent("a1c2e3f4-Signup sketch.png"))

    let light = renderWindow(notes: lightNotes, active: "Landing page", dark: false)
    let dark = renderWindow(notes: darkNotes, active: "Config research", dark: true)
    try! FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try! compose(light: light, dark: dark).write(to: docs.appendingPathComponent("screenshot.png"))
    print("Wrote \(docs.lastPathComponent)/screenshot.png")

    let menus = MenuShots.capture(notes: lightNotes, active: "Landing page")
    if menus.count == 2 {
        try! MenuShots.compose(menus).write(to: docs.appendingPathComponent("menus.png"))
        print("Wrote \(docs.lastPathComponent)/menus.png")
    } else {
        print("Could not capture the menus; docs/menus.png was left unchanged")
    }
}
