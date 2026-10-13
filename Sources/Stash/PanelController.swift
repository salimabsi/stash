import AppKit
import Quartz

private let itemDragType = NSPasteboard.PasteboardType("com.salimabsi.stash.items")
private let sectionDragType = NSPasteboard.PasteboardType("com.salimabsi.stash.section")

private final class StashWindow: NSWindow {
    var onEscape: () -> Void = {}
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.end(panel) }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }
}

/// The composer's field editor: pasting files or an image attaches them instead of
/// inserting their names as text.
private final class ComposerEditor: NSTextView {
    var onPasteAttachments: (NSPasteboard) -> Bool = { _ in false }

    override func paste(_ sender: Any?) {
        if !onPasteAttachments(.general) { super.paste(sender) }
    }
}

/// The window's body. The window itself is borderless, so the rounded corners,
/// hairline edge and solid background all come from this view.
private final class BackgroundView: NSView {
    var onDrop: (NSPasteboard) -> Bool = { _ in false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 26
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.918, green: 0.918, blue: 0.929, alpha: 1)).cgColor
        layer?.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.1).cgColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Attachments.pasteboardHasAttachments(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop(sender.draggingPasteboard)
    }
}

private enum Row {
    case header(Section)
    case item(Item)
}

@MainActor
final class PanelController: NSObject {
    private let store: Store
    private lazy var window: StashWindow = makeWindow()

    private let table = ItemTableView()
    private let scrollView = NSScrollView()
    private let search = SearchPill()
    private let composer = Composer()
    private let composerEditor = ComposerEditor()
    private let toast = ToastLabel()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton()
    private let switcher = SectionSwitcher()

    private var rows: [Row] = []
    private var query = ""
    private var expanded: Set<Item.ID> = []
    private var editing: Item.ID?

    var onOpenSettings: () -> Void = {}

    init(store: Store) {
        self.store = store
        super.init()
        store.onChange = { [weak self] in self?.reload() }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
    }

    var isVisible: Bool { window.isVisible }

    /// Closes the window whenever any of it is on screen, even if another app has focus;
    /// only a window that is fully covered by others is brought forward instead.
    func toggle() {
        isVisible && window.occlusionState.contains(.visible) ? hide() : show()
    }

    func show() {
        store.reloadIfChangedOnDisk()
        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible { window.alphaValue = 0 }
        window.makeKeyAndOrderFront(nil)
        if switcher.isHidden { window.makeFirstResponder(composer.field) }
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.14; window.animator().alphaValue = 1 }
        }
    }

    /// Hiding the app, not just the window, hands focus back to the app the user came from.
    func hide() {
        closeSwitcher()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; window.animator().alphaValue = 0 }) {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            NSApp.hide(nil)
        }
    }

    func reveal(_ id: Item.ID) {
        guard window.isVisible, let row = rowIndex(of: id) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func addPendingAttachments(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        composer.pending += paths
        show()
    }

    func openSwitcher() {
        if !window.isVisible { show() }
        switcher.isHidden = false
        switcher.present(sections: store.sections, active: store.activeSection?.id, showingAll: store.showAll)
    }

    func promptNewSection(level: Int = 1) {
        if !window.isVisible { show() }
        ask(title: level == 2 ? "New Subsection" : "New Section", initial: "", confirm: "Create") { [weak self] name in
            self?.store.addSection(name, level: level)
        }
    }

    func openDrawing() {
        DrawingWindowController.open { [weak self] png, copy in
            guard let self, let path = Attachments.save(png, named: "Drawing.png") else { return }
            if copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([Attachments.url(for: path) as NSURL])
                NSPasteboard.general.setData(png, forType: .png)
            }
            self.addPendingAttachments([path])
            if copy { self.toast.show("Drawing copied") }
        }
    }

    func captureScreenshot() {
        let wasVisible = window.isVisible
        if wasVisible { window.orderOut(nil) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString.prefix(6)).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if FileManager.default.fileExists(atPath: file.path), let path = Attachments.importFile(file) {
                    try? FileManager.default.removeItem(at: file)
                    self.addPendingAttachments([path])
                } else if wasVisible {
                    self.show()
                }
            }
        }
        try? process.run()
    }

    func attachFiles(to id: Item.ID? = nil) {
        if !window.isVisible { show() }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let paths = panel.urls.compactMap(Attachments.importFile)
            if let id { self.store.attach(paths, to: id) } else { self.composer.pending += paths }
        }
    }

    // MARK: - Menus shared with the menu bar icon

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(MenuAction("Switch Section…", key: "k") { [weak self] in self?.openSwitcher() })
        let titled = store.sections.filter { $0.level > 0 }
        if !titled.isEmpty {
            let all = MenuAction("All Sections") { [weak self] in self?.store.showAll = true }
            all.state = store.showAll ? .on : .off
            menu.addItem(all)
            for section in titled {
                let entry = MenuAction(section.title) { [weak self] in
                    self?.store.showAll = false
                    self?.store.activate(section.id)
                }
                entry.indentationLevel = section.level == 2 ? 1 : 0
                entry.state = !store.showAll && section.id == store.activeSection?.id ? .on : .off
                menu.addItem(entry)
            }
        }
        menu.addItem(MenuAction("New Section…") { [weak self] in self?.promptNewSection() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Create Drawing…") { [weak self] in self?.openDrawing() })
        menu.addItem(MenuAction("Capture Screenshot…") { [weak self] in self?.captureScreenshot() })
        menu.addItem(MenuAction("Clear Completed", enabled: store.allItems.contains(where: \.done)) { [weak self] in self?.store.clearDone() })
        menu.addItem(.separator())
        let onTop = MenuAction("Keep Window on Top") { Settings.shared.keepOnTop.toggle() }
        onTop.state = Settings.shared.keepOnTop ? .on : .off
        menu.addItem(onTop)
        menu.addItem(MenuAction("Reveal Notes in Finder") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.fileURL])
        })
        menu.addItem(MenuAction("Settings…", key: ",") { [weak self] in self?.onOpenSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Quit Stash", key: "q") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: - Rows

    private func reload() {
        guard editing == nil else { return }
        let selected = selectedIDs
        rows = []
        let source = query.isEmpty ? store.visibleSections : store.sections
        for section in source {
            let items = query.isEmpty ? section.items : section.items.filter { $0.text.localizedCaseInsensitiveContains(query) }
            if section.level > 0, query.isEmpty || !items.isEmpty { rows.append(.header(section)) }
            rows += items.map(Row.item)
        }
        table.reloadData()
        let restore = IndexSet(rows.indices.filter { if case .item(let item) = rows[$0] { return selected.contains(item.id) } else { return false } })
        table.selectRowIndexes(restore, byExtendingSelection: false)

        let hasItems = rows.contains { if case .item = $0 { return true } else { return false } }
        emptyLabel.isHidden = hasItems
        let key = Settings.shared.triggerKey.symbol
        if !query.isEmpty {
            emptyLabel.stringValue = "No notes match “\(query)”."
        } else if let active = store.activeSection, active.level > 0, !store.showAll {
            emptyLabel.stringValue = "Nothing in \(active.title) yet.\nSelect text anywhere and press \(key) twice."
        } else {
            emptyLabel.stringValue = "Nothing here yet.\nSelect text anywhere and press \(key) twice.\nType # Name to start a section."
        }
    }

    private var selectedIDs: Set<Item.ID> {
        Set(table.selectedRowIndexes.compactMap { row in
            guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
            return item.id
        })
    }

    private func rowIndex(of id: Item.ID) -> Int? {
        rows.firstIndex { if case .item(let item) = $0 { return item.id == id } else { return false } }
    }

    private func item(at row: Int) -> Item? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item
    }

    // MARK: - Note actions

    private func copy(_ ids: Set<Item.ID>, asList: Bool = false) {
        let notes = store.items(ids)
        let text = asList ? store.listText(for: ids) : store.text(for: ids)
        let attachments = notes.flatMap(\.attachments)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        Attachments.write(text: text, attachments: attachments, to: .general)
        toast.show(asList ? "Copied as list" : ids.count > 1 ? "Copied \(ids.count) notes" : "Copied")
    }

    private func startEditing(_ id: Item.ID) {
        guard let row = rowIndex(of: id), let item = store.item(id) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ItemCell else { return }
        editing = id
        let editor = cell.beginEditing(
            text: item.text,
            onHeightChange: { [weak self] in
                guard let self, let row = self.rowIndex(of: id) else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    self.table.noteHeightOfRows(withIndexesChanged: [row])
                }
            },
            onFinish: { [weak self] text, removed in self?.finishEditing(id, text: text, removing: removed) }
        )
        window.makeFirstResponder(editor)
        table.noteHeightOfRows(withIndexesChanged: [row])
    }

    private func finishEditing(_ id: Item.ID, text: String?, removing removed: Set<String>) {
        guard editing == id else { return }
        editing = nil
        if let text { store.edit(id, text: text, removing: removed) }
        reload()
        if let row = rowIndex(of: id) { table.selectRowIndexes([row], byExtendingSelection: false) }
        // When editing ended because the user clicked into another field, leave focus there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.firstResponder === self.window || self.window.firstResponder == nil else { return }
            self.window.makeFirstResponder(self.table)
        }
    }

    private func editInWindow(_ id: Item.ID) {
        guard let item = store.item(id) else { return }
        EditorWindowController.edit(item.text) { [weak self] text in
            self?.store.update(id, text: text)
        }
    }

    private func toggleExpanded(_ ids: Set<Item.ID>) {
        if ids.isSubset(of: expanded) { expanded.subtract(ids) } else { expanded.formUnion(ids) }
        let indexes = IndexSet(ids.compactMap(rowIndex))
        table.reloadData(forRowIndexes: indexes, columnIndexes: [0])
        table.noteHeightOfRows(withIndexesChanged: indexes)
    }

    private func isLong(_ item: Item) -> Bool {
        item.text.components(separatedBy: "\n").count > 3 || item.text.count > 140
    }

    private func submitComposer() {
        let text = composer.field.stringValue
        switch store.submit(text, attachments: composer.pending) {
        case .note(let id):
            composer.field.stringValue = ""
            composer.pending = []
            composer.fitHeight()
            if let row = rowIndex(of: id) { table.scrollRowToVisible(row) }
        case .section:
            composer.field.stringValue = ""
            composer.fitHeight()
            store.showAll = false
            if let title = store.activeSection?.title { toast.show("Now adding to \(title)") }
        case nil:
            break
        }
    }

    private func focusList(selectingLast: Bool) {
        guard let last = rows.lastIndex(where: { if case .item = $0 { return true } else { return false } }) else { return }
        if table.selectedRowIndexes.isEmpty || selectingLast {
            let first = rows.firstIndex { if case .item = $0 { return true } else { return false } } ?? last
            let row = selectingLast ? last : first
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        window.makeFirstResponder(table)
    }

    private func closeSwitcher() {
        guard !switcher.isHidden else { return }
        switcher.isHidden = true
        window.makeFirstResponder(composer.field)
    }

    private func handleEscape() {
        if !switcher.isHidden {
            closeSwitcher()
        } else if !query.isEmpty {
            search.field.stringValue = ""
            query = ""
            reload()
            window.makeFirstResponder(composer.field)
        } else {
            hide()
        }
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": window.makeFirstResponder(search.field)
        case "n": window.makeFirstResponder(composer.field)
        case "k": switcher.isHidden ? openSwitcher() : closeSwitcher()
        case "w": hide()
        default: return false
        }
        return true
    }

    private func pasteAttachments(_ pasteboard: NSPasteboard) -> Bool {
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let imageOnly = pasteboard.availableType(from: [.png, .tiff]) != nil && pasteboard.string(forType: .string) == nil
        guard hasFiles || imageOnly else { return false }
        composer.pending += Attachments.importFromPasteboard(pasteboard)
        return true
    }

    private func ask(title: String, initial: String, confirm: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
    }

    private func applySettings() {
        window.level = Settings.shared.keepOnTop ? .floating : .normal
        reload()
    }

    // MARK: - Layout

    private func makeWindow() -> StashWindow {
        let window = StashWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 300, height: 320)
        window.level = Settings.shared.keepOnTop ? .floating : .normal
        window.delegate = self
        window.onEscape = { [weak self] in self?.handleEscape() }
        window.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }

        window.contentView = makeContent()

        if !window.setFrameUsingName("StashWindow"), let screen = NSScreen.main?.visibleFrame {
            window.setFrame(NSRect(x: screen.maxX - 380, y: screen.maxY - 660, width: 360, height: 640), display: false)
        }
        window.setFrameAutosaveName("StashWindow")
        reload()
        return window
    }

    private func makeContent() -> NSView {
        let root = BackgroundView()
        root.registerForDraggedTypes([.fileURL, .png, .tiff])
        root.onDrop = { [weak self] pasteboard in
            guard let self else { return false }
            let paths = Attachments.importFromPasteboard(pasteboard)
            self.composer.pending += paths
            return !paths.isEmpty
        }

        search.field.delegate = self
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        moreButton.isBordered = false
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.toolTip = "Sections, drawing, settings"
        let more = FillView()
        more.fill = Palette.raised
        more.radius = 16
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        more.addSubview(moreButton)
        NSLayoutConstraint.activate([
            more.widthAnchor.constraint(equalToConstant: 32),
            more.heightAnchor.constraint(equalToConstant: 32),
            moreButton.topAnchor.constraint(equalTo: more.topAnchor),
            moreButton.bottomAnchor.constraint(equalTo: more.bottomAnchor),
            moreButton.leadingAnchor.constraint(equalTo: more.leadingAnchor),
            moreButton.trailingAnchor.constraint(equalTo: more.trailingAnchor),
        ])
        let topBar = NSStackView(views: [search, more])
        topBar.spacing = 8
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureTable()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)

        composer.field.delegate = self
        composer.plusButton.target = self
        composer.plusButton.action = #selector(showPlusMenu)
        composer.strip.onRemove = { [weak self] path in self?.composer.pending.removeAll { $0 == path } }
        composer.strip.onOpen = { [weak self] path, view in
            guard let self else { return }
            self.preview(self.composer.pending, opening: path, from: view)
        }
        composerEditor.isFieldEditor = true
        composerEditor.onPasteAttachments = { [weak self] in self?.pasteAttachments($0) ?? false }

        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.maximumNumberOfLines = 0
        switcher.isHidden = true
        switcher.onClose = { [weak self] in self?.closeSwitcher() }
        switcher.onPick = { [weak self] choice in self?.pickSection(choice) }

        for view in [topBar, scrollView, composer, emptyLabel, toast, switcher] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Palette.cardInset),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Palette.cardInset),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -4),
            composer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Palette.cardInset),
            composer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Palette.cardInset),
            composer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -40),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            switcher.topAnchor.constraint(equalTo: root.topAnchor),
            switcher.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            switcher.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = .zero
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.actions = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([itemDragType, sectionDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    private func pickSection(_ choice: SectionSwitcher.Choice) {
        switch choice {
        case .showAll:
            store.showAll = true
        case .section(let id):
            store.showAll = false
            store.activate(id)
        case .create(let name, let level):
            store.showAll = false
            store.addSection(name, level: level)
        }
        closeSwitcher()
    }

    @objc private func showMoreMenu() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height + 4), in: moreButton)
    }

    @objc private func showPlusMenu() {
        let menu = NSMenu()
        menu.addItem(MenuAction("Attach Files…") { [weak self] in self?.attachFiles() })
        menu.addItem(MenuAction("Create Drawing…") { [weak self] in self?.openDrawing() })
        menu.addItem(MenuAction("Capture Screenshot…") { [weak self] in self?.captureScreenshot() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: composer.plusButton.bounds.height + 4), in: composer.plusButton)
    }

    /// The table takes clicks on non-control subviews for itself, so attachment tiles never
    /// see a double-click; it is routed to the file under the pointer here instead.
    private func preview(_ paths: [String], opening path: String, from view: NSView) {
        QuickLook.shared.show(paths.map(Attachments.url), at: paths.firstIndex(of: path) ?? 0, from: view)
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard let item = item(at: row) else { return }
        if let point = NSApp.currentEvent?.locationInWindow,
           let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCell,
           let hit = cell.attachment(at: point) {
            preview(item.attachments, opening: hit.path, from: hit.view)
            return
        }
        startEditing(item.id)
    }
}

// MARK: - Window

extension PanelController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        composer.focused = false
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === composer.field ? composerEditor : nil
    }
}

// MARK: - Table data and delegate

extension PanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let section):
            let cell = (tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell) ?? HeaderCell()
            cell.configure(section)
            return cell
        case .item(let item):
            let cell = (tableView.makeView(withIdentifier: ItemCell.identifier, owner: nil) as? ItemCell) ?? ItemCell()
            cell.configure(item, expanded: expanded.contains(item.id))
            cell.onToggle = { [weak self] in self?.store.toggle([item.id]) }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard case .item(let item) = rows[row] else { return PlainRowView() }
        let view = CardRowView()
        view.tagColor = item.color
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard editing == nil, query.isEmpty else { return nil }
        let writer = NSPasteboardItem()
        switch rows[row] {
        case .item(let item):
            writer.setString(item.id.uuidString, forType: itemDragType)
            writer.setString(item.text, forType: .string)
        case .header(let section):
            writer.setString(section.id.uuidString, forType: sectionDragType)
        }
        return writer
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        if let sectionID = items.first?.string(forType: sectionDragType).flatMap(UUID.init) {
            store.moveSection(sectionID, to: sectionDropIndex(row))
            return true
        }
        let ids = Set(items.compactMap { $0.string(forType: itemDragType).flatMap(UUID.init) })
        guard !ids.isEmpty, let target = dropTarget(row) else { return false }
        store.move(ids, to: target.section, at: target.index)
        return true
    }

    /// A section dropped above a row lands before the section that row starts or belongs to.
    private func sectionDropIndex(_ row: Int) -> Int {
        for candidate in rows[min(row, rows.count)...] {
            if case .header(let section) = candidate, let index = store.sections.firstIndex(where: { $0.id == section.id }) {
                return index
            }
        }
        return store.sections.count
    }

    /// Dropping above a note lands before it; dropping above a header or past the end
    /// lands at the end of the section before it.
    private func dropTarget(_ row: Int) -> (section: Section.ID, index: Int)? {
        if let item = item(at: row), let section = store.section(containing: item.id),
           let index = section.items.firstIndex(where: { $0.id == item.id }) {
            return (section.id, index)
        }
        for previous in rows[..<min(row, rows.count)].reversed() {
            switch previous {
            case .item(let item):
                if let section = store.section(containing: item.id),
                   let index = section.items.firstIndex(where: { $0.id == item.id }) {
                    return (section.id, index + 1)
                }
            case .header(let section):
                return (section.id, 0)
            }
        }
        if row < rows.count, case .header(let section) = rows[row] { return (section.id, 0) }
        return store.activeSection.map { ($0.id, $0.items.count) }
    }
}

// MARK: - Context menus

extension PanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.menuRow

        if rows.indices.contains(row), case .header(let section) = rows[row] {
            menu.addItem(MenuAction("Add Notes Here") { [weak self] in self?.store.activate(section.id) })
            menu.addItem(MenuAction("Rename…") { [weak self] in
                self?.ask(title: "Rename Section", initial: section.title, confirm: "Rename") { name in
                    self?.store.renameSection(section.id, to: name)
                }
            })
            if section.level == 1 {
                menu.addItem(MenuAction("New Subsection…") { [weak self] in
                    self?.store.activate(section.id)
                    self?.promptNewSection(level: 2)
                })
            }
            menu.addItem(.separator())
            menu.addItem(MenuAction("Delete Section") { [weak self] in self?.store.deleteSection(section.id) })
            return
        }

        guard let clicked = item(at: row) else {
            menu.addItem(MenuAction("New Section…") { [weak self] in self?.promptNewSection() })
            menu.addItem(MenuAction("Clear Completed", enabled: store.allItems.contains(where: \.done)) { [weak self] in self?.store.clearDone() })
            return
        }

        let ids = table.selectedRowIndexes.contains(row) ? selectedIDs : [clicked.id]
        let notes = store.items(ids)
        let allDone = notes.allSatisfy(\.done)
        let allExpanded = ids.isSubset(of: expanded)

        menu.addItem(MenuAction("Copy", key: "c") { [weak self] in self?.copy(ids) })
        menu.addItem(MenuAction("Copy as List", key: "c", modifiers: [.command, .shift]) { [weak self] in self?.copy(ids, asList: true) })
        menu.addItem(.separator())
        menu.addItem(MenuAction(allDone ? "Mark as Not Done" : "Mark as Done", key: " ", modifiers: []) { [weak self] in self?.store.toggle(ids) })
        menu.addItem(MenuAction(allExpanded ? "Collapse" : "Expand", enabled: notes.contains(where: isLong)) { [weak self] in self?.toggleExpanded(ids) })
        menu.addItem(.separator())
        menu.addItem(MenuAction("Attach File…", enabled: ids.count == 1) { [weak self] in self?.attachFiles(to: clicked.id) })
        menu.addItem(MenuAction("Edit Inline", key: "\r", modifiers: [], enabled: ids.count == 1) { [weak self] in self?.startEditing(clicked.id) })
        menu.addItem(MenuAction("Edit in New Window", key: "\r", enabled: ids.count == 1) { [weak self] in self?.editInWindow(clicked.id) })
        if ids.count > 1 {
            menu.addItem(MenuAction("Merge Notes", key: "m", modifiers: [.command, .shift]) { [weak self] in self?.store.merge(ids) })
        }

        let moveItem = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
        let moveMenu = NSMenu()
        let current = store.section(containing: clicked.id)?.id
        for section in store.sections {
            let entry = MenuAction(section.title.isEmpty ? "No Section" : section.title) { [weak self] in
                self?.store.move(ids, to: section.id, at: section.items.count)
            }
            entry.indentationLevel = section.level == 2 ? 1 : 0
            entry.state = section.id == current && ids.count == 1 ? .on : .off
            moveMenu.addItem(entry)
        }
        moveMenu.addItem(.separator())
        moveMenu.addItem(MenuAction("New Section…") { [weak self] in
            self?.ask(title: "New Section", initial: "", confirm: "Create") { name in
                guard let self, let section = self.store.addSection(name) else { return }
                self.store.move(ids, to: section, at: 0)
            }
        })
        moveItem.submenu = moveMenu
        menu.addItem(moveItem)

        menu.addItem(.separator())
        let colors = NSMenuItem()
        colors.view = ColorTagMenuView(current: notes.count == 1 ? notes[0].color : nil) { [weak self] color in
            self?.store.setColor(color, for: ids)
        }
        menu.addItem(colors)
        menu.addItem(.separator())
        menu.addItem(MenuAction("Delete", key: "\u{8}", modifiers: []) { [weak self] in self?.store.remove(ids) })
    }
}

// MARK: - Keyboard actions from the list

extension PanelController: ItemTableActions {
    func tableToggle() { store.toggle(selectedIDs) }
    func tableDelete() { store.remove(selectedIDs) }
    func tableCopy() { copy(selectedIDs) }
    func tableCopyAsList() { copy(selectedIDs, asList: true) }
    func tableMerge() { store.merge(selectedIDs) }
    func tableUndo() { store.undo() }

    func tableExpand() {
        let long = Set(store.items(selectedIDs).filter(isLong).map(\.id))
        if !long.isEmpty { toggleExpanded(long) }
    }

    func tableEdit() {
        if selectedIDs.count == 1, let id = selectedIDs.first { startEditing(id) }
    }

    func tableEditInWindow() {
        if selectedIDs.count == 1, let id = selectedIDs.first { editInWindow(id) }
    }

    func tableLeaveBottom() {
        table.deselectAll(nil)
        window.makeFirstResponder(composer.field)
    }

    func tableType(_ characters: String) {
        table.deselectAll(nil)
        window.makeFirstResponder(composer.field)
        composer.field.currentEditor()?.insertText(characters)
        composer.fitHeight()
    }
}

// MARK: - Text fields

extension PanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === search.field {
            query = field.stringValue.trimmingCharacters(in: .whitespaces)
            reload()
        } else if field === composer.field {
            composer.fitHeight()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === composer.field {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                submitComposer()
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertNewlineIgnoringFieldEditor(nil)
                composer.fitHeight()
                return true
            case #selector(NSResponder.moveUp(_:)) where composer.field.stringValue.isEmpty:
                focusList(selectingLast: true)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where composer.field.stringValue.isEmpty && !composer.pending.isEmpty:
                composer.pending.removeLast()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                handleEscape()
                return true
            default:
                return false
            }
        }

        if control === search.field {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)):
                focusList(selectingLast: false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                handleEscape()
                return true
            default:
                return false
            }
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === composer.field { composer.focused = false }
    }
}

final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
