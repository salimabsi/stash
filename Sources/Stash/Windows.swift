import AppKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let onSave: (String) -> Void
    private static var open: [EditorWindowController] = []

    static func edit(_ text: String, onSave: @escaping (String) -> Void) {
        let controller = EditorWindowController(text: text, onSave: onSave)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.textView)
    }

    private init(text: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Note"
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 220)
        window.center()
        super.init(window: window)
        window.delegate = self

        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.drawsBackground = false

        let hint = NSTextField(labelWithString: "Markdown supported  ·  ⌘↩ to save  ·  Esc to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let save = NSButton(title: "Save", target: self, action: #selector(saveAndClose))
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = [.command]
        save.bezelStyle = .push
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .push

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [hint, spacer, cancel, save])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 14)

        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        window.contentView = stack
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func saveAndClose() {
        onSave(textView.string)
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

/// The confirmation shown near the top of the screen when something is captured while
/// the window is closed, so a capture never happens silently.
@MainActor
final class CaptureToast {
    enum Style { case saved, warning }

    private var window: NSPanel?
    private var generation = 0

    func show(title: String, detail: String, style: Style = .saved) {
        let window = self.window ?? makeWindow()
        self.window = window
        guard let content = window.contentView as? ToastContent else { return }
        content.set(title: title, detail: detail, style: style)
        content.layoutSubtreeIfNeeded()

        // The screen with the pointer is the one the user is looking at; NSScreen.main
        // follows the key window, which belongs to another app at capture time.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = content.fittingSize
        let final = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12, width: size.width, height: size.height)

        generation += 1
        let current = generation
        let wasVisible = window.isVisible && window.alphaValue > 0
        window.setFrame(wasVisible ? final : final.offsetBy(dx: 0, dy: 8), display: true)
        if !wasVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(final, display: true)
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            }) {
                if self.generation == current { window.orderOut(nil) }
            }
        }
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ToastContent()
        return panel
    }
}

final class ToastContent: NSView {
    private static let radius: CGFloat = 16

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.cell?.wraps = true
        detailLabel.cell?.truncatesLastVisibleLine = true
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        for view in [icon, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            text.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func set(title: String, detail: String, style: CaptureToast.Style) {
        let (symbol, colors): (String, [NSColor]) = switch style {
        case .saved: ("checkmark.circle.fill", [.white, .systemGreen])
        case .warning: ("exclamationmark.triangle.fill", [.white, .systemOrange])
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors)))
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        detailLabel.maximumNumberOfLines = style == .warning ? 2 : 1
        detailLabel.preferredMaxLayoutWidth = 280
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.995, alpha: 1)).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.08).cgColor
    }
}
