import AppKit

enum Palette {
    static let card = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.085) : NSColor(white: 1, alpha: 0.94) }
    static let fill = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.055) }
    static let raised = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 1, alpha: 0.75) }
    static let done = NSColor.systemGreen
    static let cardInset: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let radius: CGFloat = 14
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension TagColor {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }
}

/// A rounded, filled background with an optional ring, drawn in `draw(_:)` so the
/// dynamic colours follow light and dark mode without any manual refresh.
class FillView: NSView {
    var fill: NSColor = Palette.fill { didSet { needsDisplay = true } }
    var radius: CGFloat = Palette.radius { didSet { needsDisplay = true } }
    var ring: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if let ring {
            ring.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }
}

// MARK: - Table

@MainActor
protocol ItemTableActions: AnyObject {
    func tableToggle()
    func tableDelete()
    func tableCopy()
    func tableCopyAsList()
    func tableEdit()
    func tableEditInWindow()
    func tableMerge()
    func tableUndo()
    func tableExpand()
    func tableLeaveBottom()
    func tableType(_ characters: String)
}

final class ItemTableView: NSTableView {
    weak var actions: ItemTableActions?
    private(set) var menuRow = -1

    /// Selecting the right-clicked note shows it with the card's own ring, instead of
    /// the square outline the table would otherwise draw around the row.
    override func menu(for event: NSEvent) -> NSMenu? {
        menuRow = row(at: convert(event.locationInWindow, from: nil))
        if menuRow >= 0, !selectedRowIndexes.contains(menuRow), delegate?.tableView?(self, shouldSelectRow: menuRow) ?? true {
            selectRowIndexes([menuRow], byExtendingSelection: false)
        }
        return menu
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 49 where modifiers.isEmpty:
            actions?.tableToggle()
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty:
            actions?.tableEdit()
        case 51, 117:
            actions?.tableDelete()
        case 124 where modifiers.isEmpty, 123 where modifiers.isEmpty:
            actions?.tableExpand()
        case 125 where modifiers.isEmpty && selectedRow == numberOfRows - 1:
            actions?.tableLeaveBottom()
        default:
            if modifiers.subtracting(.shift).isEmpty, let chars = event.characters,
               let scalar = chars.unicodeScalars.first, CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains(scalar) {
                actions?.tableType(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (modifiers, key, event.keyCode) {
        case ([.command], "c", _): actions?.tableCopy()
        case ([.command, .shift], "c", _): actions?.tableCopyAsList()
        case ([.command, .shift], "m", _): actions?.tableMerge()
        case ([.command], "z", _): actions?.tableUndo()
        case ([.command], _, 36), ([.command], _, 76): actions?.tableEditInWindow()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class CardRowView: NSTableRowView {
    var tagColor: TagColor? { didSet { needsDisplay = true } }
    override var isSelected: Bool { didSet { needsDisplay = true } }

    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Palette.cardInset, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: Palette.radius, yRadius: Palette.radius)
        Palette.card.setFill()
        path.fill()
        if isSelected {
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: Palette.radius - 1, yRadius: Palette.radius - 1)
            ring.lineWidth = 2
            (tagColor?.nsColor ?? .controlAccentColor).setStroke()
            ring.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

final class PlainRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}

final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let line = NSBox()
        line.boxType = .separator
        for view in [label, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Palette.cardInset + 4)
        NSLayoutConstraint.activate([
            leading,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Palette.cardInset - 4),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ section: Section) {
        leading.constant = Palette.cardInset + (section.level == 2 ? 14 : 4)
        let title = section.level == 2 ? section.title : section.title.uppercased()
        label.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: section.level == 2 ? 11 : 10, weight: .semibold),
            .foregroundColor: section.level == 2 ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            .kern: section.level == 2 ? 0.2 : 0.8,
        ])
    }
}

final class ItemCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ItemCell")

    let label = NSTextField(wrappingLabelWithString: "")
    var onToggle: () -> Void = {}
    private let checkButton = NSButton()
    private let strip = AttachmentStrip(removable: false)
    private let content = NSStackView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        checkButton.isBordered = false
        checkButton.imagePosition = .imageOnly
        checkButton.target = self
        checkButton.action = #selector(toggleTapped)

        label.isSelectable = false
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.setViews([label, strip], in: .top)

        for view in [checkButton, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = Palette.cardInset + Palette.cardPadding
        NSLayoutConstraint.activate([
            checkButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            checkButton.topAnchor.constraint(equalTo: topAnchor, constant: 3 + 11),
            checkButton.widthAnchor.constraint(equalToConstant: 16),
            checkButton.heightAnchor.constraint(equalToConstant: 16),

            content.leadingAnchor.constraint(equalTo: checkButton.trailingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -leading),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3 + 10),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(3 + 10)),
            label.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Item, expanded: Bool) {
        checkButton.image = Self.checkImage(done: item.done, tag: item.color)
        endEditing()
        label.isHidden = item.text.isEmpty
        label.maximumNumberOfLines = expanded ? 0 : 3
        label.attributedStringValue = Markdown.render(item.text, done: item.done)
        strip.paths = item.attachments
        strip.isHidden = item.attachments.isEmpty
        strip.alphaValue = item.done ? 0.55 : 1
    }

    private(set) var editor: InlineEditor?

    /// `onFinish` gets nil text on cancel, along with the attachments removed while editing.
    func beginEditing(text: String, onHeightChange: @escaping () -> Void, onFinish: @escaping (String?, Set<String>) -> Void) -> InlineEditor {
        endEditing()
        let editor = InlineEditor(text: text)
        var removed = Set<String>()
        editor.onHeightChange = onHeightChange
        editor.onFinish = { [weak self] text in
            self?.endEditing()
            onFinish(text, removed)
        }
        strip.removable = true
        strip.onRemove = { [weak self] path in
            guard let self else { return }
            removed.insert(path)
            self.strip.paths.removeAll { $0 == path }
            self.strip.isHidden = self.strip.paths.isEmpty
            onHeightChange()
        }
        label.isHidden = true
        content.insertArrangedSubview(editor, at: 0)
        editor.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        layoutSubtreeIfNeeded()
        editor.fitHeight()
        self.editor = editor
        return editor
    }

    func attachment(at windowPoint: NSPoint) -> (path: String, view: NSView)? {
        for case let tile as AttachmentTile in strip.arrangedSubviews where tile.bounds.contains(tile.convert(windowPoint, from: nil)) {
            return (tile.path, tile)
        }
        return nil
    }

    func endEditing() {
        guard let editor else { return }
        self.editor = nil
        editor.removeFromSuperview()
        strip.removable = false
        strip.onRemove = { _ in }
    }

    /// Wrapping labels report their height for whatever width they last laid out at,
    /// so the width is fed back in or automatic row heights come out wrong.
    override func layout() {
        super.layout()
        if label.preferredMaxLayoutWidth != label.frame.width {
            label.preferredMaxLayoutWidth = label.frame.width
            super.layout()
        }
    }

    static func checkImage(done: Bool, tag: TagColor?) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if done {
                Palette.done.setFill()
                circle.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 4.6, y: 8.2))
                check.line(to: NSPoint(x: 7, y: 5.6))
                check.line(to: NSPoint(x: 11.6, y: 10.6))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else if let tag {
                tag.nsColor.withAlphaComponent(0.22).setFill()
                circle.fill()
                tag.nsColor.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1.2
                circle.stroke()
            }
            return true
        }
    }

    @objc private func toggleTapped() { onToggle() }
}

/// Multi-line, in-place editing for a note. Return saves, Shift- or Option-Return adds a
/// line, Esc cancels, and moving focus elsewhere saves. `onFinish` gets nil on cancel.
final class InlineEditor: NSTextView, NSTextViewDelegate {
    var onHeightChange: () -> Void = {}
    var onFinish: (String?) -> Void = { _ in }
    private var heightConstraint: NSLayoutConstraint!
    private var finished = false

    init(text: String) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        insertionPointColor = .controlAccentColor
        defaultParagraphStyle = paragraph
        typingAttributes = attributes
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        delegate = self

        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: 17)
        heightConstraint.isActive = true
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fitHeight()
    }

    func fitHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = max(ceil(layoutManager.usedRect(for: textContainer).height), 17)
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        heightConstraint.constant = height
        onHeightChange()
    }

    func textDidChange(_ notification: Notification) {
        fitHeight()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                finish(string)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(nil)
            return true
        default:
            return false
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finish(string) }
        return resigned
    }

    private func finish(_ text: String?) {
        guard !finished else { return }
        finished = true
        onFinish(text)
    }
}

final class AttachmentStrip: NSStackView {
    var paths: [String] = [] { didSet { rebuild() } }
    var onRemove: (String) -> Void = { _ in }
    var onOpen: (String, NSView) -> Void = { path, _ in NSWorkspace.shared.open(Attachments.url(for: path)) }
    var removable: Bool { didSet { rebuild() } }

    init(removable: Bool) {
        self.removable = removable
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        alignment = .top
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let shown = paths.prefix(4)
        for path in shown {
            let tile = AttachmentTile(path: path, removable: removable)
            tile.onRemove = { [weak self] in self?.onRemove(path) }
            tile.onOpen = { [weak self, weak tile] in
                guard let tile else { return }
                self?.onOpen(path, tile)
            }
            addArrangedSubview(tile)
        }
        if paths.count > shown.count {
            let more = NSTextField(labelWithString: "+\(paths.count - shown.count)")
            more.font = .systemFont(ofSize: 12, weight: .medium)
            more.textColor = .secondaryLabelColor
            addArrangedSubview(more)
        }
    }
}

private final class AttachmentTile: NSView {
    var onRemove: () -> Void = {}
    var onOpen: () -> Void = {}
    let path: String

    init(path: String, removable: Bool) {
        self.path = path
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = Attachments.displayName(path) + "\nDouble-click to open"

        var constraints = [
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 52),
        ]
        if Attachments.isImage(path) {
            layer?.backgroundColor = NSColor.white.cgColor
            layer?.contents = Attachments.thumbnail(path)
            layer?.contentsGravity = .resizeAspectFill
        } else {
            let image = NSImageView(image: Attachments.thumbnail(path))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            addSubview(image)
            let name = NSTextField(labelWithString: Attachments.displayName(path))
            name.font = .systemFont(ofSize: 9)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingMiddle
            name.alignment = .center
            name.translatesAutoresizingMaskIntoConstraints = false
            addSubview(name)
            constraints += [
                image.centerXAnchor.constraint(equalTo: centerXAnchor),
                image.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                image.widthAnchor.constraint(equalToConstant: 28),
                image.heightAnchor.constraint(equalToConstant: 28),
                name.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 2),
                name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            ]
        }

        if removable {
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")!, target: self, action: #selector(removeTapped))
            remove.isBordered = false
            remove.symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.65)])
                .applying(.init(pointSize: 13, weight: .regular))
            remove.translatesAutoresizingMaskIntoConstraints = false
            addSubview(remove)
            constraints += [
                remove.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onOpen()
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func removeTapped() { onRemove() }
}

// MARK: - Window chrome

final class SearchPill: NSView {
    let field = NSTextField()

    init() {
        super.init(frame: .zero)
        let background = FillView()
        background.fill = Palette.raised
        background.radius = 16
        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true

        for view in [background, icon, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class ComposerField: NSTextField {
    var onFocus: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus() }
        return accepted
    }
}

final class Composer: NSView {
    let field = ComposerField()
    let plusButton = NSButton()
    let strip = AttachmentStrip(removable: true)
    private let background = FillView()
    private var heightConstraint: NSLayoutConstraint!
    private let minHeight: CGFloat = 34
    private let maxHeight: CGFloat = 160

    var focused = false {
        didSet { background.ring = focused ? .controlAccentColor : nil }
    }

    var pending: [String] = [] {
        didSet {
            strip.paths = pending
            strip.isHidden = pending.isEmpty
        }
    }

    init() {
        super.init(frame: .zero)
        background.fill = Palette.card
        plusButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add attachment")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .light))
        plusButton.isBordered = false
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "Attach files, create a drawing or capture a screenshot"

        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.placeholderString = "Add a note, type a prompt, or describe a task"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocus = { [weak self] in self?.focused = true }
        strip.isHidden = true

        let stack = NSStackView(views: [strip])
        stack.orientation = .vertical
        stack.alignment = .leading

        for view in [background, stack, plusButton, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = field.heightAnchor.constraint(equalToConstant: minHeight)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Palette.cardPadding),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Palette.cardPadding),
            plusButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Palette.cardPadding - 1),
            plusButton.centerYAnchor.constraint(equalTo: field.topAnchor, constant: 8.5),
            field.leadingAnchor.constraint(equalTo: plusButton.trailingAnchor, constant: 9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Palette.cardPadding),
            field.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 2),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func fitHeight() {
        let text = field.currentEditor()?.string ?? field.stringValue
        let measured = ((text.isEmpty ? " " : text + (text.hasSuffix("\n") ? " " : "")) as NSString).boundingRect(
            with: NSSize(width: max(field.bounds.width - 4, 50), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: field.font!]
        )
        heightConstraint.constant = min(max(ceil(measured.height) + 2, minHeight), maxHeight)
    }
}

final class ToastLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let background = FillView()
        background.fill = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.25, alpha: 0.95) : NSColor(white: 0.12, alpha: 0.9) }
        background.radius = 12
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        for view in [background, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String) {
        generation += 1
        let current = generation
        label.stringValue = message
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; self.animator().alphaValue = 0 }
        }
    }
}

/// The row of colour dots in a note's context menu. The first one clears the tag.
final class ColorTagMenuView: NSView {
    private let onPick: (TagColor?) -> Void
    private let options: [TagColor?] = [nil] + TagColor.allCases

    init(current: TagColor?, onPick: @escaping (TagColor?) -> Void) {
        self.onPick = onPick
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: 30))
        let row = NSStackView()
        row.spacing = 6
        for (index, option) in options.enumerated() {
            let button = NSButton(image: Self.dot(option, selected: option == current), target: self, action: #selector(picked(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = option?.rawValue.capitalized ?? "No Color"
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked(_ sender: NSButton) {
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(options[sender.tag])
    }

    private static func dot(_ color: TagColor?, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            if let color {
                color.nsColor.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
                if selected {
                    NSColor.labelColor.withAlphaComponent(0.6).setStroke()
                    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
            } else {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: 4.5, y: 9))
                check.line(to: NSPoint(x: 7.5, y: 6))
                check.line(to: NSPoint(x: 13.5, y: 12.5))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.labelColor.withAlphaComponent(selected ? 1 : 0.45).setStroke()
                check.stroke()
            }
            return true
        }
    }
}
