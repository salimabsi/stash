import AppKit
import ApplicationServices

/// Native apps answer the Accessibility API directly. Everything else is read by pressing
/// Cmd+C, reading the clipboard and then restoring the user's previous clipboard contents.
@MainActor
enum SelectionReader {
    static func read(completion: @escaping (String?) -> Void) {
        let app = NSWorkspace.shared.frontmostApplication
        if !isChromiumBased(app), let text = viaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            completion(text)
        } else {
            viaCopy(completion: completion)
        }
    }

    /// Chromium and Electron apps only expose plain text over Accessibility, if anything,
    /// while their clipboard carries HTML, so copying keeps bold, code and links.
    private static func isChromiumBased(_ app: NSRunningApplication?) -> Bool {
        guard let frameworks = app?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)
        else { return false }
        return names.contains { $0 == "Electron Framework.framework" || $0.hasSuffix("Chrome Framework.framework") || $0.hasSuffix("Chromium Framework.framework") }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
    }

    private static func viaCopy(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let startCount = pasteboard.changeCount

        pressCommandC()

        let deadline = Date().addingTimeInterval(0.5)
        func poll() {
            if pasteboard.changeCount != startCount {
                let text = Markdown.fromPasteboard(pasteboard)
                restore(saved, to: pasteboard)
                completion(text)
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            } else {
                completion(nil)
            }
        }
        poll()
    }

    private static func pressCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
