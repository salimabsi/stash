import AppKit

enum DrawingTool: CaseIterable {
    case select, pen, text, rectangle, ellipse, arrow, line

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "scribble"
        case .text: "textformat"
        case .rectangle: "square"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        }
    }

    var name: String {
        switch self {
        case .select: "Select (V)"
        case .pen: "Pen (P)"
        case .text: "Text (T)"
        case .rectangle: "Rectangle (R)"
        case .ellipse: "Ellipse (O)"
        case .arrow: "Arrow (A)"
        case .line: "Line (L)"
        }
    }

    var key: String {
        switch self {
        case .select: "v"
        case .pen: "p"
        case .text: "t"
        case .rectangle: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        }
    }
}

/// `ink` is black on a light canvas and white on a dark one, so drawings made in either
/// appearance stay legible.
enum InkColor: CaseIterable {
    case ink, red, orange, green, blue, purple

    var color: NSColor {
        switch self {
        case .ink: .labelColor
        case .red: .systemRed
        case .orange: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }
}

struct Stroke {
    enum Kind {
        case pen([CGPoint])
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(CGPoint, CGPoint)
        case line(CGPoint, CGPoint)
        case text(String, CGPoint)
    }

    var kind: Kind
    var color: InkColor
    var width: CGFloat
    var offset: CGSize = .zero

    static let textFont = NSFont.systemFont(ofSize: 18, weight: .medium)

    var bounds: CGRect {
        let raw: CGRect
        switch kind {
        case .pen(let points):
            let xs = points.map(\.x), ys = points.map(\.y)
            raw = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        case .rectangle(let rect), .ellipse(let rect):
            raw = rect
        case .arrow(let a, let b), .line(let a, let b):
            raw = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .text(let string, let point):
            let size = (string as NSString).size(withAttributes: [.font: Self.textFont])
            raw = CGRect(origin: point, size: size)
        }
        return raw.offsetBy(dx: offset.width, dy: offset.height).insetBy(dx: -width - 4, dy: -width - 4)
    }

    func draw() {
        NSGraphicsContext.current?.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: offset.width, yBy: offset.height)
        transform.concat()
        color.color.setStroke()
        color.color.setFill()

        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch kind {
        case .pen(let points):
            guard let first = points.first else { break }
            path.move(to: first)
            if points.count == 1 {
                path.line(to: first)
            }
            for i in 1..<max(points.count, 1) {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                path.curve(to: mid, controlPoint1: points[i - 1], controlPoint2: points[i - 1])
            }
            if let last = points.last { path.line(to: last) }
            path.stroke()
        case .rectangle(let rect):
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).withWidth(width).stroke()
        case .ellipse(let rect):
            NSBezierPath(ovalIn: rect).withWidth(width).stroke()
        case .line(let a, let b):
            path.move(to: a)
            path.line(to: b)
            path.stroke()
        case .arrow(let a, let b):
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(12, width * 4)
            for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                path.move(to: b)
                path.line(to: CGPoint(x: b.x + head * cos(angle + side), y: b.y + head * sin(angle + side)))
            }
            path.stroke()
        case .text(let string, let point):
            (string as NSString).draw(at: point, withAttributes: [.font: Self.textFont, .foregroundColor: color.color])
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

private extension NSBezierPath {
    func withWidth(_ width: CGFloat) -> NSBezierPath {
        lineWidth = width
        return self
    }
}

final class DrawingCanvas: NSView, NSTextFieldDelegate {
    var tool: DrawingTool = .pen { didSet { commitText(); selected = nil; window?.invalidateCursorRects(for: self) } }
    var color: InkColor = .ink { didSet { if let selected { strokes[selected].color = color; needsDisplay = true } } }
    var width: CGFloat = 3
    var onChange: () -> Void = {}

    private(set) var strokes: [Stroke] = [] { didSet { needsDisplay = true; onChange() } }
    private var history: [[Stroke]] = []
    private var draft: Stroke?
    private var dragStart: CGPoint = .zero
    private var selected: Int? { didSet { needsDisplay = true } }
    private var textField: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var isEmpty: Bool { strokes.isEmpty && (textField?.stringValue.isEmpty ?? true) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        for stroke in strokes { stroke.draw() }
        draft?.draw()
        if let selected, strokes.indices.contains(selected) {
            let outline = NSBezierPath(roundedRect: strokes[selected].bounds, xRadius: 4, yRadius: 4)
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        switch tool {
        case .select:
            selected = strokes.lastIndex { $0.bounds.contains(point) }
            if selected != nil { record() }
        case .text:
            commitText()
            beginText(at: point)
        case .pen:
            draft = Stroke(kind: .pen([point]), color: color, width: width)
        default:
            draft = shape(from: point, to: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            guard let selected else { return }
            strokes[selected].offset.width += point.x - dragStart.x
            strokes[selected].offset.height += point.y - dragStart.y
            dragStart = point
        case .pen:
            if case .pen(var points) = draft?.kind {
                points.append(point)
                draft?.kind = .pen(points)
            }
        case .text:
            break
        default:
            draft = shape(from: dragStart, to: point, constrained: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let draft else { return }
        self.draft = nil
        if draft.bounds.width < 2 * draft.width + 10, draft.bounds.height < 2 * draft.width + 10, tool != .pen {
            needsDisplay = true
            return
        }
        record()
        strokes.append(draft)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117, let selected {
            record()
            strokes.remove(at: selected)
            self.selected = nil
        } else if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
                  let match = DrawingTool.allCases.first(where: { $0.key == key }) {
            tool = match
            (window?.windowController as? DrawingWindowController)?.syncToolbar()
        } else {
            super.keyDown(with: event)
        }
    }

    func undo() {
        commitText()
        guard let previous = history.popLast() else { return }
        selected = nil
        strokes = previous
    }

    func clear() {
        commitText()
        guard !strokes.isEmpty else { return }
        record()
        selected = nil
        strokes = []
    }

    func pngData() -> Data? {
        commitText()
        guard !strokes.isEmpty else { return nil }
        let content = strokes.map(\.bounds).reduce(strokes[0].bounds) { $0.union($1) }.insetBy(dx: -24, dy: -24).intersection(bounds)
        let previousSelection = selected
        selected = nil
        defer { selected = previousSelection }
        let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.width * 2), pixelsHigh: Int(content.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let scaled else { return nil }
        scaled.size = content.size
        guard let base = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        let flip = NSAffineTransform()
        flip.translateX(by: -content.minX, yBy: content.maxY)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            draw(content)
        }
        NSGraphicsContext.restoreGraphicsState()
        return scaled.representation(using: .png, properties: [:])
    }

    private func record() {
        history.append(strokes)
        if history.count > 200 { history.removeFirst() }
    }

    private func shape(from a: CGPoint, to b: CGPoint, constrained: Bool = false) -> Stroke {
        var end = b
        if constrained {
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            end = CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
        }
        let rect = CGRect(x: min(a.x, end.x), y: min(a.y, end.y), width: abs(end.x - a.x), height: abs(end.y - a.y))
        let kind: Stroke.Kind
        switch tool {
        case .rectangle: kind = .rectangle(rect)
        case .ellipse: kind = .ellipse(rect)
        case .arrow: kind = .arrow(a, end)
        default: kind = .line(a, end)
        }
        return Stroke(kind: kind, color: color, width: width)
    }

    private func beginText(at point: CGPoint) {
        let field = NSTextField(frame: NSRect(x: point.x - 2, y: point.y - 2, width: 240, height: 28))
        field.font = Stroke.textFont
        field.textColor = color.color
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Type…"
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        record()
        strokes.append(Stroke(kind: .text(text, CGPoint(x: field.frame.minX + 2, y: field.frame.minY + 2)), color: color, width: 0))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }
}

@MainActor
final class DrawingWindowController: NSWindowController, NSWindowDelegate {
    private static var current: DrawingWindowController?

    private let canvas = DrawingCanvas()
    private var toolButtons: [DrawingTool: NSButton] = [:]
    private var colorButtons: [InkColor: NSButton] = [:]
    private let widthButton = NSButton()
    private let onSave: (Data, Bool) -> Void

    static func open(onSave: @escaping (Data, _ copy: Bool) -> Void) {
        let controller = current ?? DrawingWindowController(onSave: onSave)
        current = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
    }

    private init(onSave: @escaping (Data, Bool) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Drawing"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
        syncToolbar()
    }

    required init?(coder: NSCoder) { fatalError() }

    func syncToolbar() {
        for (tool, button) in toolButtons {
            button.contentTintColor = tool == canvas.tool ? .white : .secondaryLabelColor
            (button.superview as? FillView)?.fill = tool == canvas.tool ? .controlAccentColor : .clear
        }
        for (ink, button) in colorButtons {
            button.image = swatch(ink.color, selected: ink == canvas.color)
        }
        widthButton.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Stroke width")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: canvas.width < 3 ? .ultraLight : canvas.width < 6 ? .regular : .heavy))
    }

    private func buildContent() {
        let root = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .push
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        save.bezelColor = .controlAccentColor
        let copySave = NSButton(title: "Copy and Save", target: self, action: #selector(copyAndSave))
        copySave.bezelStyle = .push
        copySave.keyEquivalent = "s"
        copySave.keyEquivalentModifierMask = [.command, .shift]
        let actions = NSStackView(views: [copySave, save])
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actions)

        var items: [NSView] = DrawingTool.allCases.map { tool in
            let button = NSButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.name)!, target: self, action: #selector(pickTool(_:)))
            button.isBordered = false
            button.toolTip = tool.name
            button.tag = DrawingTool.allCases.firstIndex(of: tool)!
            toolButtons[tool] = button
            return wrap(button, size: 28, radius: 8)
        }
        items.append(divider())
        for (index, ink) in InkColor.allCases.enumerated() {
            let button = NSButton(image: swatch(ink.color, selected: false), target: self, action: #selector(pickColor(_:)))
            button.isBordered = false
            button.tag = index
            colorButtons[ink] = button
            items.append(wrap(button, size: 22, radius: 11))
        }
        items.append(divider())
        widthButton.isBordered = false
        widthButton.target = self
        widthButton.action = #selector(cycleWidth)
        widthButton.toolTip = "Stroke width"
        widthButton.contentTintColor = .secondaryLabelColor
        items.append(wrap(widthButton, size: 28, radius: 8))
        let undo = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!, target: self, action: #selector(undo))
        undo.isBordered = false
        undo.toolTip = "Undo (⌘Z)"
        undo.contentTintColor = .secondaryLabelColor
        undo.keyEquivalent = "z"
        undo.keyEquivalentModifierMask = [.command]
        items.append(wrap(undo, size: 28, radius: 8))
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear")!, target: self, action: #selector(clear))
        clear.isBordered = false
        clear.toolTip = "Clear"
        clear.contentTintColor = .secondaryLabelColor
        items.append(wrap(clear, size: 28, radius: 8))

        let toolbar = NSStackView(views: items)
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let toolbarBackground = NSVisualEffectView()
        toolbarBackground.material = .popover
        toolbarBackground.state = .active
        toolbarBackground.wantsLayer = true
        toolbarBackground.layer?.cornerRadius = 12
        toolbarBackground.layer?.borderWidth = 0.5
        toolbarBackground.layer?.borderColor = NSColor.separatorColor.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbarBackground.translatesAutoresizingMaskIntoConstraints = false
        toolbarBackground.addSubview(toolbar)
        root.addSubview(toolbarBackground)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            actions.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: toolbarBackground.topAnchor),
            toolbar.bottomAnchor.constraint(equalTo: toolbarBackground.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: toolbarBackground.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: toolbarBackground.trailingAnchor),
            toolbarBackground.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        window?.contentView = root
    }

    private func wrap(_ button: NSButton, size: CGFloat, radius: CGFloat) -> NSView {
        let background = FillView()
        background.fill = .clear
        background.radius = radius
        button.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(button)
        NSLayoutConstraint.activate([
            background.widthAnchor.constraint(equalToConstant: size),
            background.heightAnchor.constraint(equalToConstant: size),
            button.topAnchor.constraint(equalTo: background.topAnchor),
            button.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])
        return background
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func swatch(_ color: NSColor, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).stroke()
            return true
        }
    }

    @objc private func pickTool(_ sender: NSButton) {
        canvas.tool = DrawingTool.allCases[sender.tag]
        syncToolbar()
        window?.makeFirstResponder(canvas)
    }

    @objc private func pickColor(_ sender: NSButton) {
        canvas.color = InkColor.allCases[sender.tag]
        syncToolbar()
    }

    @objc private func cycleWidth() {
        canvas.width = canvas.width < 3 ? 3 : canvas.width < 6 ? 6 : 2
        syncToolbar()
    }

    @objc private func undo() { canvas.undo() }
    @objc private func clear() { canvas.clear() }

    @objc private func save() { finish(copy: false) }
    @objc private func copyAndSave() { finish(copy: true) }

    private func finish(copy: Bool) {
        guard let png = canvas.pngData() else {
            NSSound.beep()
            return
        }
        onSave(png, copy)
        window?.close()
    }

    override func cancelOperation(_ sender: Any?) {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}
