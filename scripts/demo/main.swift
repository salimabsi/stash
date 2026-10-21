// Renders docs/demo.mp4: a scripted walkthrough built from the real Stash views, drawn
// offscreen frame by frame next to a made-up chat app. Nothing touches the real screen,
// keyboard or notes. Run through scripts/make-demo.sh.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .aqua)

let canvas = CGSize(width: 960, height: 600)
let pixelScale: CGFloat = 2
let fps = 30.0
let duration = 25.5
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

// MARK: - Helpers

func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ease(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
func span(_ t: Double, _ start: Double, _ end: Double) -> Double { ease((t - start) / (end - start)) }
func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
}

func find<T: NSView>(_ view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
    if let view = view as? T, match(view) { return view }
    for subview in view.subviews {
        if let found: T = find(subview, where: match) { return found }
    }
    return nil
}

func snapshot(_ view: NSView) -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func drawWindow(_ content: NSBitmapImageRep?, in frame: CGRect, radius: CGFloat, background: NSColor, alpha: CGFloat = 1) {
    guard alpha > 0.001 else { return }
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.setAlpha(alpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    let body = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.shadowBlurRadius = 34
    shadow.set()
    background.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    if let content {
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        content.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    NSColor.black.withAlphaComponent(0.1).setStroke()
    body.lineWidth = 1
    body.stroke()
    context.endTransparencyLayer()
    context.restoreGState()
}

// MARK: - A made-up chat app

final class ChatView: NSView {
    static let size = CGSize(width: 500, height: 444)
    let question = "What's the safest way to version a config format?"
    let keySentence = "Keep the core format declarative, and add an escape hatch only when a real need appears."
    var selection: Double = 0
    var input = ""

    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 448, height: CGFloat.greatestFiniteMagnitude))
    private var keyRange = NSRange()
    private let answerOrigin = CGPoint(x: 26, y: 124)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: ChatView.size))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 12
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.13, alpha: 1), .paragraphStyle: paragraph]
        var bold = body
        bold[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold)
        storage.append(NSAttributedString(string: "There are three common approaches: a version field in the file, a schema URL, or no version at all with additive-only changes.\n", attributes: body))
        keyRange = NSRange(location: storage.length, length: (keySentence as NSString).length)
        storage.append(NSAttributedString(string: keySentence, attributes: bold))
        storage.append(NSAttributedString(string: " Executable configs are harder to validate, cache and migrate.\n", attributes: body))
        storage.append(NSAttributedString(string: "For migrations, ship a command that rewrites old files and prints what changed.", attributes: body))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    required init?(coder: NSCoder) { fatalError() }

    var inputRect: CGRect { CGRect(x: 16, y: bounds.height - 16 - 54, width: bounds.width - 32, height: 54) }

    /// A point on the selected sentence, `fraction` of the way through it, in view coordinates.
    func pointInSentence(_ fraction: Double) -> CGPoint {
        layout.ensureLayout(for: container)
        let index = keyRange.location + min(Int(Double(keyRange.length) * fraction), keyRange.length - 1)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return CGPoint(x: answerOrigin.x + rect.minX, y: answerOrigin.y + rect.midY)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()

        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 16 + CGFloat(index) * 20, y: 13, width: 12, height: 12)).fill()
        }
        let title = NSAttributedString(string: "Chat", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
        title.draw(at: CGPoint(x: (bounds.width - title.size().width) / 2, y: 11))
        NSColor(white: 0, alpha: 0.07).setFill()
        CGRect(x: 0, y: 38, width: bounds.width, height: 1).fill()

        let ask = NSAttributedString(string: question, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(white: 0.13, alpha: 1)])
        let askSize = ask.boundingRect(with: CGSize(width: 300, height: 200), options: [.usesLineFragmentOrigin]).size
        let bubble = CGRect(x: bounds.width - 26 - askSize.width - 28, y: 58, width: askSize.width + 28, height: askSize.height + 18)
        NSColor(white: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 16, yRadius: 16).fill()
        ask.draw(with: bubble.insetBy(dx: 14, dy: 9), options: [.usesLineFragmentOrigin])

        layout.ensureLayout(for: container)
        let selected = NSRange(location: keyRange.location, length: Int(Double(keyRange.length) * clamp(selection)))
        if selected.length > 0 {
            NSColor(srgbRed: 0.70, green: 0.84, blue: 1, alpha: 1).setFill()
            let glyphs = layout.glyphRange(forCharacterRange: selected, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container) { rect, _ in
                rect.offsetBy(dx: self.answerOrigin.x, dy: self.answerOrigin.y).insetBy(dx: 0, dy: -1).fill()
            }
        }
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: answerOrigin)

        let field = NSBezierPath(roundedRect: inputRect, xRadius: 16, yRadius: 16)
        NSColor(white: 0.975, alpha: 1).setFill()
        field.fill()
        NSColor(white: 0, alpha: 0.12).setStroke()
        field.stroke()
        let text = input.isEmpty ? "Message" : input
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: input.isEmpty ? NSColor.tertiaryLabelColor : NSColor(white: 0.13, alpha: 1)])
            .draw(with: CGRect(x: inputRect.minX + 16, y: inputRect.minY + 17, width: inputRect.width - 70, height: 22), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let send = CGRect(x: inputRect.maxX - 40, y: inputRect.midY - 14, width: 28, height: 28)
        (input.isEmpty ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
        NSBezierPath(ovalIn: send).fill()
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: send.midX, y: send.maxY - 8))
        arrow.line(to: CGPoint(x: send.midX, y: send.minY + 8))
        arrow.move(to: CGPoint(x: send.midX - 5, y: send.minY + 13))
        arrow.line(to: CGPoint(x: send.midX, y: send.minY + 8))
        arrow.line(to: CGPoint(x: send.midX + 5, y: send.minY + 13))
        arrow.lineWidth = 2
        arrow.lineCapStyle = .round
        NSColor.white.setStroke()
        arrow.stroke()
    }
}

// MARK: - Scene

let chat = ChatView()
let chatWindow = NSWindow(contentRect: CGRect(origin: .zero, size: ChatView.size), styleMask: [.borderless], backing: .buffered, defer: false)
chatWindow.contentView = chat
let chatFrame = CGRect(x: 40, y: 104, width: ChatView.size.width, height: ChatView.size.height)

func chatPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: chatFrame.minX + p.x, y: chatFrame.maxY - p.y) }

try! """
# Config research
- [ ] Compare TOML, YAML and JSON5 for hand-edited config files <!-- blue -->
- [x] Skim how Cargo structures its config docs
""".write(to: Store.directory.appendingPathComponent("stash.md"), atomically: true, encoding: .utf8)
UserDefaults.standard.set("Config research", forKey: "activeSection")
UserDefaults.standard.set(false, forKey: "showAllSections")

let store = MainActor.assumeIsolated { Store() }
let panel = MainActor.assumeIsolated { PanelController(store: store) }
let stashWindow: NSWindow = MainActor.assumeIsolated {
    _ = panel.isVisible
    return NSApp.windows.last { $0.title == "Stash" }!
}
let stashSize = CGSize(width: 360, height: 444)
stashWindow.setContentSize(stashSize)
let stashRoot = stashWindow.contentView!
let stashFrame = CGRect(x: canvas.width - 40 - stashSize.width, y: 104, width: stashSize.width, height: stashSize.height)
let table: ItemTableView = find(stashRoot)!
let composer: Composer = find(stashRoot)!
let copiedToast: ToastLabel = find(stashRoot)!
let stashBackground = NSColor(srgbRed: 0.918, green: 0.918, blue: 0.929, alpha: 1)

func stashPoint(_ view: NSView, _ p: CGPoint) -> CGPoint {
    let q = view.convert(p, to: stashRoot)
    return CGPoint(x: stashFrame.minX + q.x, y: stashFrame.minY + q.y)
}

@MainActor
func noteRow(_ id: Item.ID) -> Int? {
    (0..<table.numberOfRows).first { (table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? ItemCell)?.label.stringValue == store.item(id)?.text.replacingOccurrences(of: "**", with: "") }
}

@MainActor
func noteCenter(_ id: Item.ID) -> CGPoint {
    guard let row = noteRow(id) else { return CGPoint(x: stashFrame.midX, y: stashFrame.midY) }
    let rect = table.rect(ofRow: row)
    return stashPoint(table, CGPoint(x: rect.midX + 30, y: rect.midY))
}

@MainActor
func checkboxCenter(_ id: Item.ID) -> CGPoint {
    guard let row = noteRow(id) else { return CGPoint(x: stashFrame.midX, y: stashFrame.midY) }
    let rect = table.rect(ofRow: row)
    return stashPoint(table, CGPoint(x: rect.minX + Palette.cardInset + Palette.cardPadding + 8, y: rect.minY + 3 + 11 + 8))
}

let capturedToast = MainActor.assumeIsolated { ToastContent() }
let toastWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
toastWindow.contentView = capturedToast
capturedToast.set(title: "Saved to Config research", detail: "Keep the core format declarative, and add an escape hatch…", style: .saved)
toastWindow.setContentSize(capturedToast.fittingSize)
let toastImage = snapshot(capturedToast)

let drawing = MainActor.assumeIsolated { DrawingWindowController(onSave: { _, _ in }) }
let drawingWindow = drawing.window!
let drawingSize = CGSize(width: 540, height: 360)
drawingWindow.setContentSize(drawingSize)
let drawingCanvas: DrawingCanvas = find(drawingWindow.contentView!)!
let drawingFrame = CGRect(x: (canvas.width - drawingSize.width) / 2, y: 120, width: drawingSize.width, height: drawingSize.height)

func drawingPoint(_ p: CGPoint) -> CGPoint {
    let q = drawingCanvas.convert(p, to: drawingWindow.contentView)
    return CGPoint(x: drawingFrame.minX + q.x, y: drawingFrame.minY + q.y)
}

func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
    let event = NSEvent.mouseEvent(with: type, location: drawingCanvas.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: drawingWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    switch type {
    case .leftMouseDown: drawingCanvas.mouseDown(with: event)
    case .leftMouseDragged: drawingCanvas.mouseDragged(with: event)
    default: drawingCanvas.mouseUp(with: event)
    }
}

func key(_ character: String, _ code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: drawingWindow.windowNumber,
                                 context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    drawingCanvas.keyDown(with: event)
}

/// A stroke drawn between two times, following `path` (canvas-view coordinates).
struct StrokeScript {
    let start: Double
    let end: Double
    let path: [CGPoint]
    var stage = 0

    func point(_ t: Double) -> CGPoint {
        let p = clamp((t - start) / (end - start)) * Double(path.count - 1)
        let i = min(Int(p), path.count - 2)
        return mix(path[i], path[i + 1], p - Double(i))
    }
}

func wave(_ from: CGPoint, length: CGFloat, amplitude: CGFloat) -> [CGPoint] {
    (0...24).map { i in
        let x = CGFloat(i) / 24
        return CGPoint(x: from.x + x * length, y: from.y + sin(x * .pi * 4) * amplitude)
    }
}

var strokes = [
    StrokeScript(start: 18.0, end: 18.7, path: [CGPoint(x: 150, y: 90), CGPoint(x: 390, y: 250)]),
    StrokeScript(start: 18.9, end: 19.5, path: wave(CGPoint(x: 180, y: 140), length: 180, amplitude: 6)),
    StrokeScript(start: 19.6, end: 20.1, path: wave(CGPoint(x: 180, y: 190), length: 120, amplitude: 6)),
    StrokeScript(start: 20.4, end: 20.9, path: [CGPoint(x: 470, y: 300), CGPoint(x: 400, y: 258)]),
]

// MARK: - Timeline

let capturedText = "**Keep the core format declarative, and add an escape hatch only when a real need appears.**"
let prompt = "Ask for an example migration command"
var capturedID: Item.ID?
var promptID: Item.ID?

struct Event {
    let time: Double
    let run: @MainActor () -> Void
}

var events: [Event] = [
    Event(time: 4.0) { capturedID = store.add(capturedText) },
    Event(time: 8.9) { composer.focused = true },
    Event(time: 10.9) {
        if case .note(let id) = store.submit(prompt) { promptID = id }
        composer.field.stringValue = ""
        composer.fitHeight()
    },
    Event(time: 11.7) { if let id = promptID, let row = noteRow(id) { table.selectRowIndexes([row], byExtendingSelection: false) } },
    Event(time: 12.0) { copiedToast.show("Copied") },
    Event(time: 13.4) { chat.input = prompt },
    Event(time: 15.6) { if let id = promptID { store.toggle([id]) } },
    Event(time: 17.95) { key("r", 15) },
    Event(time: 18.8) { key("p", 35) },
    Event(time: 20.3) {
        key("a", 0)
        drawingCanvas.color = .red
        drawing.syncToolbar()
    },
    Event(time: 21.2) {
        table.deselectAll(nil)
        if let png = drawingCanvas.pngData(), let path = Attachments.save(png, named: "Drawing.png") {
            composer.pending = [path]
        }
        composer.field.stringValue = ""
        composer.focused = true
    },
]

let captions: [(Double, Double, String)] = [
    (0.0, 3.9, "Select anything worth keeping while you work with AI"),
    (3.9, 6.4, "Press ⇧ twice: it's saved, and you never left the chat"),
    (6.4, 8.4, "Click the S in the menu bar to open Stash"),
    (8.4, 11.3, "Queue the prompts you want to try next"),
    (11.3, 14.6, "Copy one straight into your next prompt"),
    (14.6, 16.3, "Tick it off when it's done"),
    (16.3, 21.3, "⌘ + ⇧ twice opens the drawing editor"),
    (21.3, 23.2, "Your sketch is attached, ready to paste or save"),
    (23.2, duration, "Stash  ·  github.com/salimabsi/stash"),
]

let keys: [(Double, [String])] = [
    (3.4, ["⇧"]), (3.65, ["⇧", "⇧"]),
    (10.9, ["↩"]),
    (12.0, ["⌘", "C"]),
    (13.4, ["⌘", "V"]),
    (16.5, ["⌘"]), (16.65, ["⌘", "⇧"]), (16.8, ["⌘", "⇧", "⇧"]),
    (17.95, ["R"]), (18.8, ["P"]), (20.3, ["A"]),
    (21.0, ["⌘", "⇧", "S"]),
]

let menuBarS = CGPoint(x: canvas.width - 96, y: canvas.height - 12)
let clicks: [Double] = [7.5, 8.9, 11.7, 13.1, 15.6]

/// Where the pointer is at time t: a list of (arrive-by time, target) legs, each eased.
@MainActor
func cursor(_ t: Double) -> CGPoint {
    let legs: [(Double, Double, () -> CGPoint)] = [
        (0.0, 0.0, { chatPoint(CGPoint(x: 250, y: 330)) }),
        (1.2, 2.0, { chatPoint(chat.pointInSentence(0)) }),
        (2.0, 3.2, { chatPoint(chat.pointInSentence(1)) }),
        (6.5, 7.4, { menuBarS }),
        (8.2, 8.85, { stashPoint(composer, CGPoint(x: 80, y: composer.bounds.midY)) }),
        (11.25, 11.65, { promptID.map(noteCenter) ?? CGPoint(x: stashFrame.midX, y: stashFrame.midY) }),
        (12.4, 13.05, { chatPoint(CGPoint(x: chat.inputRect.minX + 120, y: chat.inputRect.midY)) }),
        (14.8, 15.55, { promptID.map(checkboxCenter) ?? CGPoint(x: stashFrame.midX, y: stashFrame.midY) }),
        (17.2, 17.9, { drawingPoint(strokes[0].path[0]) }),
    ]
    var position = legs[0].2()
    for (start, end, target) in legs where t >= start {
        position = mix(position, target(), span(t, start, end))
    }
    for stroke in strokes where t >= stroke.start - 0.05 && t <= stroke.end + 0.3 {
        position = drawingPoint(stroke.point(t))
    }
    if t > 21.0 { position = mix(position, CGPoint(x: stashFrame.midX, y: stashFrame.minY + 120), span(t, 21.0, 21.8)) }
    return position
}

// MARK: - Overlays

func drawMenuBar(_ t: Double) {
    NSColor(white: 1, alpha: 0.72).setFill()
    CGRect(x: 0, y: canvas.height - 24, width: canvas.width, height: 24).fill()
    var x: CGFloat = 16
    for (index, name) in ["Chat", "File", "Edit", "View", "Window"].enumerated() {
        let label = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: index == 0 ? .bold : .regular), .foregroundColor: NSColor.black])
        label.draw(at: CGPoint(x: x, y: canvas.height - 20))
        x += label.size().width + 18
    }
    let flashing = t >= 4.0 && t < 4.9
    let icon = flashing
        ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))!
        : Logo.menuBarImage
    tinted(icon, .black).draw(in: CGRect(x: menuBarS.x - 9, y: menuBarS.y - 9, width: 18, height: 18))
    NSAttributedString(string: "Tue 9:41", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        .draw(at: CGPoint(x: canvas.width - 72, y: canvas.height - 20))
}

func drawCaption(_ t: Double) {
    for (start, end, text) in captions where t >= start - 0.3 && t < end + 0.3 {
        let alpha = min(span(t, start - 0.15, start + 0.15), 1 - span(t, end - 0.15, end + 0.15))
        guard alpha > 0 else { continue }
        let label = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
        let size = label.size()
        let pill = CGRect(x: (canvas.width - size.width) / 2 - 18, y: 8, width: size.width + 36, height: 34)
        NSColor(white: 0.08, alpha: 0.78 * alpha).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 17, yRadius: 17).fill()
        label.draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + (34 - size.height) / 2))
    }
}

func drawKeys(_ t: Double) {
    guard let (time, group) = keys.last(where: { $0.0 <= t }), t < time + 0.9 else { return }
    let alpha = 1 - span(t, time + 0.7, time + 0.9)
    let font = NSFont.systemFont(ofSize: 19, weight: .semibold)
    let caps = group.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]) }
    let capWidth = caps.map { max($0.size().width + 22, 38) }
    let width = capWidth.reduce(0, +) + CGFloat(caps.count - 1) * 6 + 16
    let box = CGRect(x: (canvas.width - width) / 2, y: 50, width: width, height: 48)
    NSColor(white: 0.08, alpha: 0.82 * alpha).setFill()
    NSBezierPath(roundedRect: box, xRadius: 13, yRadius: 13).fill()
    var x = box.minX + 8
    for (cap, w) in zip(caps, capWidth) {
        let keyRect = CGRect(x: x, y: box.minY + 7, width: w, height: 34)
        NSColor(white: 1, alpha: 0.14 * alpha).setFill()
        NSBezierPath(roundedRect: keyRect, xRadius: 8, yRadius: 8).fill()
        cap.draw(at: CGPoint(x: keyRect.midX - cap.size().width / 2, y: keyRect.midY - cap.size().height / 2))
        x += w + 6
    }
}

func drawClick(_ t: Double, at point: CGPoint) {
    for click in clicks where t >= click && t < click + 0.4 {
        let p = (t - click) / 0.4
        let radius = 6 + 20 * p
        NSColor.systemBlue.withAlphaComponent(0.45 * (1 - p)).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}

let arrow = NSCursor.arrow
func drawCursor(at point: CGPoint) {
    let image = arrow.image
    let hot = arrow.hotSpot
    image.draw(in: CGRect(x: point.x - hot.x, y: point.y - image.size.height + hot.y, width: image.size.width, height: image.size.height))
}

// MARK: - Render

let pixelWidth = Int(canvas.width * pixelScale), pixelHeight = Int(canvas.height * pixelScale)
let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: CommandLine.arguments[2])
ffmpeg.arguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(pixelWidth)x\(pixelHeight)", "-r", "\(Int(fps))",
                    "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", outputURL.path]
let pipe = Pipe()
ffmpeg.standardInput = pipe
try! ffmpeg.run()

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.scaleBy(x: pixelScale, y: pixelScale)
let graphics = NSGraphicsContext(cgContext: context, flipped: false)

MainActor.assumeIsolated {
    let frames = Int(duration * fps)
    var nextEvent = 0
    events.sort { $0.time < $1.time }
    for frame in 0..<frames {
        let t = Double(frame) / fps
        while nextEvent < events.count, events[nextEvent].time <= t {
            events[nextEvent].run()
            nextEvent += 1
        }
        for i in strokes.indices {
            if strokes[i].stage == 0, t >= strokes[i].start {
                mouse(.leftMouseDown, strokes[i].path[0])
                strokes[i].stage = 1
            }
            if strokes[i].stage == 1 {
                mouse(.leftMouseDragged, strokes[i].point(t))
                if t >= strokes[i].end {
                    mouse(.leftMouseUp, strokes[i].path.last!)
                    strokes[i].stage = 2
                }
            }
        }
        chat.selection = span(t, 2.0, 3.2)
        copiedToast.alphaValue = t >= 12.0 && t < 13.0 ? CGFloat(1 - span(t, 12.7, 13.0)) : 0
        if t >= 8.9, t < 10.9 {
            composer.field.stringValue = String(prompt.prefix(Int(Double(prompt.count) * span(t, 9.0, 10.6))))
            composer.fitHeight()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSGradient(colors: [NSColor(srgbRed: 0.86, green: 0.89, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.70, green: 0.77, blue: 0.91, alpha: 1)])!
            .draw(in: CGRect(origin: .zero, size: canvas), angle: -90)

        drawWindow(snapshot(chat), in: chatFrame, radius: 14, background: .white)

        let stashAlpha = span(t, 7.5, 7.9)
        if stashAlpha > 0 {
            let grow = 0.96 + 0.04 * stashAlpha
            let frame = CGRect(x: stashFrame.midX - stashFrame.width * grow / 2, y: stashFrame.midY - stashFrame.height * grow / 2,
                               width: stashFrame.width * grow, height: stashFrame.height * grow)
            drawWindow(snapshot(stashRoot), in: frame, radius: 26, background: stashBackground, alpha: stashAlpha)
        }

        let drawingAlpha = min(span(t, 16.9, 17.2), 1 - span(t, 21.0, 21.3))
        if drawingAlpha > 0 {
            drawWindow(snapshot(drawingWindow.contentView!), in: drawingFrame, radius: 12, background: .white, alpha: drawingAlpha)
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.withAlphaComponent(0.85 * drawingAlpha).setFill()
                NSBezierPath(ovalIn: CGRect(x: drawingFrame.minX + 16 + CGFloat(index) * 20, y: drawingFrame.maxY - 25, width: 12, height: 12)).fill()
            }
        }

        let toastAlpha = min(span(t, 4.0, 4.25), 1 - span(t, 6.0, 6.4))
        if toastAlpha > 0 {
            let size = toastImage.size
            let slide = 8 * (1 - span(t, 4.0, 4.3))
            let frame = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height - 24 - 12 - size.height + slide, width: size.width, height: size.height)
            drawWindow(toastImage, in: frame, radius: 16, background: .white, alpha: toastAlpha)
        }

        drawMenuBar(t)
        let pointer = cursor(t)
        drawClick(t, at: pointer)
        drawKeys(t)
        drawCaption(t)
        drawCursor(at: pointer)
        NSGraphicsContext.restoreGraphicsState()

        pipe.fileHandleForWriting.write(Data(bytesNoCopy: context.data!, count: pixelWidth * pixelHeight * 4, deallocator: .none))
    }
}
try! pipe.fileHandleForWriting.close()
ffmpeg.waitUntilExit()
print(ffmpeg.terminationStatus == 0 ? "Wrote \(outputURL.lastPathComponent)" : "ffmpeg failed")
