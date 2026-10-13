import AppKit
import Quartz

/// Shows attachments in the system Quick Look panel, zooming out of the thumbnail that
/// was double-clicked. The panel finds its controller through the key window's
/// responder chain, which StashWindow forwards here.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var urls: [URL] = []
    private var startIndex = 0
    private weak var sourceView: NSView?

    func show(_ urls: [URL], at index: Int, from view: NSView?) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        startIndex = index
        sourceView = view
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let view = sourceView, let window = view.window,
              (item as? URL ?? (item as? NSURL) as URL?) == urls[safe: startIndex]
        else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = urls[safe: startIndex] else { return nil }
        return NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
