import AppKit
import UniformTypeIdentifiers

/// Attached files are copied next to the notes file, so a note keeps working even if
/// the original is moved or deleted. Paths in the notes are relative: `attachments/…`.
enum Attachments {
    static let folder = "attachments"
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"]
    private static let thumbnails = NSCache<NSString, NSImage>()

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    @MainActor
    static func url(for path: String) -> URL {
        Store.directory.appendingPathComponent(path)
    }

    static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dash = name.firstIndex(of: "-"), name.distance(from: name.startIndex, to: dash) == 8 else { return name }
        return String(name[name.index(after: dash)...])
    }

    @MainActor
    static func importFile(_ source: URL) -> String? {
        let name = unique(source.lastPathComponent)
        let destination = directory().appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return "\(folder)/\(name)"
        } catch {
            return nil
        }
    }

    @MainActor
    static func save(_ data: Data, named name: String) -> String? {
        let unique = unique(name)
        do {
            try data.write(to: directory().appendingPathComponent(unique))
            return "\(folder)/\(unique)"
        } catch {
            return nil
        }
    }

    /// Files win over everything else, then image data; plain text is left to the caller.
    @MainActor
    static func importFromPasteboard(_ pasteboard: NSPasteboard) -> [String] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls.compactMap(importFile) }
        if let png = pasteboard.data(forType: .png) { return save(png, named: "Pasted Image.png").map { [$0] } ?? [] }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return save(png, named: "Pasted Image.png").map { [$0] } ?? []
        }
        return []
    }

    /// A paste counts as attachments when it carries files, or an image with no text
    /// alongside it; copied rich text often includes an image rendition that isn't meant.
    static func isAttachmentPaste(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || (pasteboard.availableType(from: [.png, .tiff]) != nil && pasteboard.string(forType: .string) == nil)
    }

    static func pasteboardHasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    @MainActor
    static func thumbnail(_ path: String) -> NSImage {
        if let cached = thumbnails.object(forKey: path as NSString) { return cached }
        let url = url(for: path)
        let image = (isImage(path) ? NSImage(contentsOf: url) : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
        thumbnails.setObject(image, forKey: path as NSString)
        return image
    }

    /// Writes the text plus the attached files, so pasting into ChatGPT or Claude brings
    /// both the prompt and its screenshots or drawings along.
    @MainActor
    static func write(text: String, attachments: [String], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = []
        if !text.isEmpty { objects.append(text as NSString) }
        objects += attachments.map { url(for: $0) as NSURL }
        if text.isEmpty, attachments.count == 1, isImage(attachments[0]), let image = NSImage(contentsOf: url(for: attachments[0])) {
            objects.append(image)
        }
        pasteboard.writeObjects(objects)
    }

    @MainActor
    private static func directory() -> URL {
        let dir = Store.directory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func unique(_ name: String) -> String {
        "\(UUID().uuidString.prefix(8).lowercased())-\(name)"
    }
}
