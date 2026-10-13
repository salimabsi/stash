import Foundation

enum TagColor: String, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray
}

struct Item: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done: Bool = false
    var color: TagColor?
    var attachments: [String] = []

    var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}

struct Section: Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// 0 for the untitled notes above the first heading, 1 for `#`, 2 for `##`.
    var level: Int
    var items: [Item] = []
}

enum ComposerResult {
    case note(Item.ID)
    case section(Section.ID)
}

/// Notes live in one Markdown file so it stays readable and hand-editable:
/// `# Title` starts a section and `## Title` a subsection, `- [ ] first line` starts a
/// note, and lines indented by two spaces continue it. A trailing `<!-- red -->` holds
/// the colour tag, and indented `![name](attachments/…)` lines list attached files.
@MainActor
final class Store {
    /// `STASH_DATA_DIR` points Stash at another folder, so screenshots and experiments can
    /// run against sample notes without touching the real ones.
    static let directory: URL = {
        let dir = ProcessInfo.processInfo.environment["STASH_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Stash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private(set) var sections: [Section] = [] {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    let fileURL = Store.directory.appendingPathComponent("stash.md")
    private var lastKnownModified: Date?
    private var pendingSave: DispatchWorkItem?
    private var undoStack: [[Section]] = []
    private let defaults = UserDefaults.standard

    init() {
        load()
    }

    // MARK: - Active section

    /// Remembered by title, since ids are regenerated every time the file is read.
    var activeSection: Section? {
        let title = defaults.string(forKey: "activeSection")
        return sections.first { $0.level > 0 && $0.title == title } ?? sections.last
    }

    func activate(_ id: Section.ID) {
        guard let section = sections.first(where: { $0.id == id }) else { return }
        defaults.set(section.title, forKey: "activeSection")
        onChange?()
    }

    var showAll: Bool {
        get { defaults.bool(forKey: "showAllSections") }
        set { defaults.set(newValue, forKey: "showAllSections"); onChange?() }
    }

    var visibleSections: [Section] {
        guard !showAll, let active = activeSection, active.level > 0,
              let start = sections.firstIndex(where: { $0.id == active.id })
        else { return sections }
        var visible = [sections[start]]
        if active.level == 1 {
            for section in sections[(start + 1)...] {
                guard section.level == 2 else { break }
                visible.append(section)
            }
        }
        return visible
    }

    // MARK: - Queries

    var allItems: [Item] { sections.flatMap(\.items) }

    func item(_ id: Item.ID) -> Item? {
        allItems.first { $0.id == id }
    }

    func section(containing id: Item.ID) -> Section? {
        sections.first { $0.items.contains { $0.id == id } }
    }

    func items(_ ids: Set<Item.ID>) -> [Item] {
        allItems.filter { ids.contains($0.id) }
    }

    func text(for ids: Set<Item.ID>) -> String {
        items(ids).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func listText(for ids: Set<Item.ID>) -> String {
        items(ids).filter { !$0.text.isEmpty }.enumerated().map { index, item in
            let lines = item.text.components(separatedBy: "\n")
            let prefix = "\(index + 1). "
            let indent = String(repeating: " ", count: prefix.count)
            return ([prefix + lines[0]] + lines.dropFirst().map { $0.isEmpty ? "" : indent + $0 }).joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    // MARK: - Mutations

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        sections = previous
        scheduleSave()
    }

    /// A single `# Name` or `## Name` line creates (or switches to) a section; anything
    /// else becomes a note in the active section.
    func submit(_ text: String, attachments: [String] = []) -> ComposerResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachments.isEmpty, !trimmed.contains("\n"), let heading = Self.heading(trimmed) {
            if let existing = sections.first(where: { $0.level > 0 && $0.title.caseInsensitiveCompare(heading.title) == .orderedSame }) {
                activate(existing.id)
                return .section(existing.id)
            }
            return addSection(heading.title, level: heading.level).map(ComposerResult.section)
        }
        return add(trimmed, attachments: attachments).map(ComposerResult.note)
    }

    @discardableResult
    func add(_ text: String, attachments: [String] = [], to sectionID: Section.ID? = nil) -> Item.ID? {
        let item = Item(text: text.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        guard !item.isEmpty else { return nil }
        let target = sectionID ?? activeSection?.id
        mutate { sections in
            let index = sections.firstIndex { $0.id == target } ?? sections.count - 1
            sections[index].items.append(item)
        }
        return item.id
    }

    func update(_ id: Item.ID, text: String) {
        edit(id, text: text, removing: [])
    }

    /// Applies an inline edit as one undoable change: the new text plus any attachments
    /// removed while editing. A note left with neither text nor attachments is deleted.
    func edit(_ id: Item.ID, text: String, removing removed: Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = item(id), current.text != trimmed || !removed.isDisjoint(with: current.attachments) else { return }
        mutate { sections in
            for s in sections.indices {
                guard let i = sections[s].items.firstIndex(where: { $0.id == id }) else { continue }
                sections[s].items[i].text = trimmed
                sections[s].items[i].attachments.removeAll { removed.contains($0) }
                if sections[s].items[i].isEmpty { sections[s].items.remove(at: i) }
            }
        }
    }

    func attach(_ paths: [String], to id: Item.ID) {
        guard !paths.isEmpty else { return }
        mutateItems([id]) { $0.attachments += paths }
    }

    func removeAttachment(_ path: String, from id: Item.ID) {
        mutate { sections in
            for s in sections.indices {
                guard let i = sections[s].items.firstIndex(where: { $0.id == id }) else { continue }
                sections[s].items[i].attachments.removeAll { $0 == path }
                if sections[s].items[i].isEmpty { sections[s].items.remove(at: i) }
            }
        }
    }

    func setColor(_ color: TagColor?, for ids: Set<Item.ID>) {
        mutateItems(ids) { $0.color = color }
    }

    func toggle(_ ids: Set<Item.ID>) {
        let markDone = !items(ids).allSatisfy(\.done)
        mutateItems(ids) { $0.done = markDone }
    }

    func remove(_ ids: Set<Item.ID>) {
        guard !ids.isEmpty else { return }
        mutate { sections in
            for s in sections.indices { sections[s].items.removeAll { ids.contains($0.id) } }
        }
    }

    func clearDone() {
        mutate { sections in
            for s in sections.indices { sections[s].items.removeAll(where: \.done) }
        }
    }

    /// Joins the notes, in list order, into the first of them.
    func merge(_ ids: Set<Item.ID>) {
        let merging = items(ids)
        guard let first = merging.first, merging.count > 1 else { return }
        let text = merging.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let attachments = merging.flatMap(\.attachments)
        let done = merging.allSatisfy(\.done)
        mutate { sections in
            for s in sections.indices {
                sections[s].items.removeAll { ids.contains($0.id) && $0.id != first.id }
                if let i = sections[s].items.firstIndex(where: { $0.id == first.id }) {
                    sections[s].items[i].text = text
                    sections[s].items[i].attachments = attachments
                    sections[s].items[i].done = done
                }
            }
        }
    }

    /// Moves the notes, keeping their order, to `index` within the target section,
    /// where `index` counts the section's notes before the move.
    func move(_ ids: Set<Item.ID>, to sectionID: Section.ID, at index: Int) {
        let moving = items(ids)
        guard !moving.isEmpty else { return }
        mutate { sections in
            guard let target = sections.firstIndex(where: { $0.id == sectionID }) else { return }
            let before = sections[target].items.prefix(index).filter { ids.contains($0.id) }.count
            for s in sections.indices { sections[s].items.removeAll { ids.contains($0.id) } }
            let insertAt = min(index - before, sections[target].items.count)
            sections[target].items.insert(contentsOf: moving, at: max(0, insertAt))
        }
    }

    /// Moves a section to `index` in the section list, counted before the move.
    func moveSection(_ id: Section.ID, to index: Int) {
        mutate { sections in
            guard let from = sections.firstIndex(where: { $0.id == id }) else { return }
            let section = sections.remove(at: from)
            sections.insert(section, at: max(0, min(from < index ? index - 1 : index, sections.count)))
        }
    }

    /// New subsections go at the end of the active section's group; new sections go last.
    @discardableResult
    func addSection(_ title: String, level: Int = 1) -> Section.ID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let section = Section(title: trimmed, level: level)
        mutate { sections in
            var index = sections.count
            if level == 2, let active = activeSection, let start = sections.firstIndex(where: { $0.id == active.id }) {
                index = start + 1
                while index < sections.count, sections[index].level == 2 { index += 1 }
            }
            sections.insert(section, at: index)
        }
        activate(section.id)
        return section.id
    }

    func renameSection(_ id: Section.ID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let section = sections.first(where: { $0.id == id }) else { return }
        let wasActive = activeSection?.id == id
        mutate { sections in
            if let s = sections.firstIndex(where: { $0.id == id }) { sections[s].title = trimmed }
        }
        if wasActive || section.title.isEmpty { activate(id) }
    }

    /// Notes in a deleted section move to the section above it, so nothing is lost.
    func deleteSection(_ id: Section.ID) {
        mutate { sections in
            guard let s = sections.firstIndex(where: { $0.id == id }) else { return }
            let orphans = sections[s].items
            sections.remove(at: s)
            if sections.isEmpty {
                sections = [Section(title: "", level: 0, items: orphans)]
            } else {
                sections[max(0, s - 1)].items.append(contentsOf: orphans)
            }
        }
    }

    /// Picks up edits made to the file in another editor since we last touched it.
    func reloadIfChangedOnDisk() {
        guard pendingSave == nil, modificationDate() != lastKnownModified else { return }
        load()
    }

    private func mutateItems(_ ids: Set<Item.ID>, _ change: @escaping (inout Item) -> Void) {
        mutate { sections in
            for s in sections.indices {
                for i in sections[s].items.indices where ids.contains(sections[s].items[i].id) {
                    change(&sections[s].items[i])
                }
            }
        }
    }

    private func mutate(_ change: (inout [Section]) -> Void) {
        var copy = sections
        change(&copy)
        if copy.isEmpty { copy = [Section(title: "", level: 0)] }
        guard copy != sections else { return }
        undoStack.append(sections)
        if undoStack.count > 100 { undoStack.removeFirst() }
        sections = copy
        scheduleSave()
    }

    // MARK: - Persistence

    private func load() {
        let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        sections = Self.parse(content)
        lastKnownModified = modificationDate()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            try? Self.serialize(self.sections).write(to: self.fileURL, atomically: true, encoding: .utf8)
            self.lastKnownModified = self.modificationDate()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    nonisolated static func heading(_ line: String) -> (title: String, level: Int)? {
        if line.hasPrefix("## ") { return (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), 2) }
        if line.hasPrefix("# ") { return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), 1) }
        return nil
    }

    nonisolated static func serialize(_ sections: [Section]) -> String {
        var blocks: [String] = []
        for section in sections {
            var lines: [String] = []
            if section.level > 0 { lines.append(String(repeating: "#", count: section.level) + " " + section.title) }
            for item in section.items {
                let textLines = item.text.components(separatedBy: "\n")
                let tag = item.color.map { " <!-- \($0.rawValue) -->" } ?? ""
                lines.append("- [\(item.done ? "x" : " ")] \(textLines[0])\(tag)")
                lines += textLines.dropFirst().map { "  " + $0 }
                lines += item.attachments.map { path in
                    let name = (path as NSString).lastPathComponent
                    return Attachments.isImage(path) ? "  ![\(name)](\(path))" : "  [\(name)](\(path))"
                }
            }
            if !lines.isEmpty { blocks.append(lines.joined(separator: "\n")) }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    nonisolated static func parse(_ content: String) -> [Section] {
        var sections = [Section(title: "", level: 0)]
        var current: Item?
        let tagPattern = try! NSRegularExpression(pattern: #"\s*<!--\s*(\w+)\s*-->\s*$"#)
        let attachmentPattern = try! NSRegularExpression(pattern: #"^!?\[[^\]]*\]\((attachments/[^)]+)\)$"#)

        func flush() {
            guard var item = current else { return }
            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { sections[sections.count - 1].items.append(item) }
            current = nil
        }

        func startItem(_ rest: String, done: Bool) {
            flush()
            var text = rest
            var color: TagColor?
            let range = NSRange(text.startIndex..., in: text)
            if let match = tagPattern.firstMatch(in: text, range: range),
               let nameRange = Range(match.range(at: 1), in: text),
               let tag = TagColor(rawValue: String(text[nameRange])) {
                color = tag
                text = String(text[..<Range(match.range, in: text)!.lowerBound])
            }
            current = Item(text: text, done: done, color: color)
        }

        for line in content.components(separatedBy: "\n") {
            if let heading = heading(line) {
                flush()
                sections.append(Section(title: heading.title, level: heading.level))
            } else if let rest = line.dropPrefix("- [ ] ") ?? line.dropPrefix("- [ ]") {
                startItem(rest, done: false)
            } else if let rest = line.dropPrefix("- [x] ") ?? line.dropPrefix("- [X] ") {
                startItem(rest, done: true)
            } else if current != nil, line.hasPrefix("  ") || line.isEmpty {
                let body = String(line.dropFirst(2))
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                if let match = attachmentPattern.firstMatch(in: trimmed, range: range),
                   let pathRange = Range(match.range(at: 1), in: trimmed) {
                    current!.attachments.append(String(trimmed[pathRange]))
                } else {
                    current!.text += "\n" + body
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                startItem(line.dropPrefix("- ") ?? line, done: false)
            }
        }
        flush()

        if sections.count > 1, sections[0].items.isEmpty { sections.removeFirst() }
        return sections
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
