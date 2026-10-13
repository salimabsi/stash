import AppKit

@MainActor
final class SectionSwitcher: NSView, NSTextFieldDelegate {
    enum Choice {
        case section(Section.ID)
        case showAll
        case create(String, level: Int)
    }

    var onPick: (Choice) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let card = FillView()
    private let field = NSTextField()
    private let list = NSStackView()
    private var sections: [Section] = []
    private var activeID: Section.ID?
    private var showingAll = false
    private var choices: [(title: String, level: Int, checked: Bool, choice: Choice)] = []
    private var highlighted = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        card.fill = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.99, alpha: 1) }
        card.radius = 12
        field.placeholderString = "Switch section or type a new name…"
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        list.orientation = .vertical
        list.spacing = 2
        list.alignment = .leading
        let separator = NSBox()
        separator.boxType = .separator

        for view in [card, field, separator, list] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(card)
        card.addSubview(field)
        card.addSubview(separator)
        card.addSubview(list)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 56),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(sections: [Section], active: Section.ID?, showingAll: Bool) {
        self.sections = sections.filter { $0.level > 0 }
        activeID = active
        self.showingAll = showingAll
        field.stringValue = ""
        rebuild()
        window?.makeFirstResponder(field)
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose() }
    }

    private func rebuild() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let heading = Store.heading(query)
        let name = heading?.title ?? query
        choices = []
        if query.isEmpty {
            choices.append(("All Sections", 0, showingAll, .showAll))
        }
        for section in sections where name.isEmpty || section.title.localizedCaseInsensitiveContains(name) {
            choices.append((section.title, section.level, !showingAll && section.id == activeID, .section(section.id)))
        }
        if !name.isEmpty, !sections.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            let level = heading?.level ?? 1
            choices.append(("Create \(level == 2 ? "subsection" : "section") “\(name)”", 0, false, .create(name, level: level)))
        }
        highlighted = min(highlighted, max(choices.count - 1, 0))
        if query.isEmpty, let current = choices.firstIndex(where: \.checked) { highlighted = current }
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, entry) in choices.prefix(12).enumerated() {
            let row = SwitcherRow(title: entry.title, level: entry.level, checked: entry.checked, highlighted: index == highlighted)
            row.onClick = { [weak self] in self?.pick(index) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }

    private func pick(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        onPick(choices[index].choice)
    }

    func controlTextDidChange(_ obj: Notification) {
        highlighted = 0
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlighted = min(highlighted + 1, min(choices.count, 12) - 1)
            render()
        case #selector(NSResponder.moveUp(_:)):
            highlighted = max(highlighted - 1, 0)
            render()
        case #selector(NSResponder.insertNewline(_:)):
            pick(highlighted)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
        default:
            return false
        }
        return true
    }
}

private final class SwitcherRow: FillView {
    var onClick: () -> Void = {}

    init(title: String, level: Int, checked: Bool, highlighted: Bool) {
        super.init(frame: .zero)
        radius = 7
        fill = highlighted ? .controlAccentColor : .clear
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: level == 1 ? .medium : .regular)
        label.textColor = highlighted ? .white : .labelColor
        label.lineBreakMode = .byTruncatingTail
        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!)
        check.contentTintColor = highlighted ? .white : .controlAccentColor
        check.isHidden = !checked
        for view in [label, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: level == 2 ? 26 : 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -8),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
}
