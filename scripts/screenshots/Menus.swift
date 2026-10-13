import AppKit

/// Menus can't be drawn offscreen, so this briefly shows a sample window, without
/// activating the app, over a solid backdrop window of its own, opens each menu and
/// captures that area. Menus are translucent, so they need the backdrop to look right,
/// and both windows sit above other apps' windows so nothing else ends up in the image.
@MainActor
enum MenuShots {
    static let backdropColor = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    private static let pad: CGFloat = 70

    struct Shot {
        let image: NSImage
        let size: CGSize
    }

    private final class Box { var shot: Shot? }

    static func capture(notes: String, active: String) -> [Shot] {
        try! notes.write(to: Store.directory.appendingPathComponent("stash.md"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(active, forKey: "activeSection")
        UserDefaults.standard.set(false, forKey: "showAllSections")
        app.appearance = NSAppearance(named: .aqua)

        let panel = PanelController(store: Store())
        _ = panel.isVisible
        let window = NSApp.windows.last { $0.title == "Stash" }!
        window.appearance = app.appearance
        window.setContentSize(windowSize)
        let screen = (NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") } ?? NSScreen.screens[0]).visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 100, y: screen.maxY - 90))

        let backdrop = NSWindow(
            contentRect: NSRect(x: window.frame.minX - pad, y: window.frame.minY - pad,
                                width: window.frame.width + pad + 420, height: window.frame.height + 2 * pad),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        backdrop.backgroundColor = backdropColor
        backdrop.level = .floating
        backdrop.isReleasedWhenClosed = false
        backdrop.orderFrontRegardless()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer {
            window.close()
            backdrop.close()
        }

        let root = window.contentView!
        let table: ItemTableView = find(in: root) { _ in true }!
        let more: NSButton = find(in: root) { $0.toolTip == "Sections, drawing, settings" }!
        var shots: [Shot] = []

        let row = table.rect(ofRow: 1)
        let point = table.convert(NSPoint(x: row.maxX - 120, y: row.midY), to: nil)
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let noteMenu = table.menu(for: click)!
        if let shot = whileOpen(noteMenu, window: window, backdrop: backdrop, open: {
            NSMenu.popUpContextMenu(noteMenu, with: click, for: table)
        }) {
            shots.append(shot)
        }

        let moreMenu = panel.makeMenu()
        if let shot = whileOpen(moreMenu, window: window, backdrop: backdrop, open: {
            moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
        }) {
            shots.append(shot)
        }
        return shots
    }

    /// Opening a menu runs a modal loop until it closes, so the capture is scheduled on a
    /// timer that also fires during menu tracking, and it closes the menu itself.
    private static func whileOpen(_ menu: NSMenu, window: NSWindow, backdrop: NSWindow, open: () -> Void) -> Shot? {
        let box = Box()
        let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                box.shot = grab(window, backdrop: backdrop)
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        open()
        return box.shot
    }

    private static func grab(_ window: NSWindow, backdrop: NSWindow) -> Shot? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        func frame(_ info: [String: Any]) -> CGRect {
            CGRect(dictionaryRepresentation: info[kCGWindowBounds as String] as! CFDictionary) ?? .zero
        }
        func number(_ info: [String: Any]) -> Int { info[kCGWindowNumber as String] as? Int ?? 0 }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let main = mine.first(where: { number($0) == window.windowNumber }),
              let back = mine.first(where: { number($0) == backdrop.windowNumber }),
              let menu = mine.first(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) == menuLevel })
        else { return nil }
        let region = frame(main).union(frame(menu)).insetBy(dx: -pad, dy: -pad).intersection(frame(back)).integral

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stash-menu-shot.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", "\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", file.path]
        try? process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: file) }
        guard let image = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:)) else { return nil }
        return Shot(image: image, size: region.size)
    }

    private static func find<T: NSView>(in view: NSView, where match: (T) -> Bool) -> T? {
        if let view = view as? T, match(view) { return view }
        for subview in view.subviews {
            if let found: T = find(in: subview, where: match) { return found }
        }
        return nil
    }

    /// The shots side by side on the backdrop colour, so the seams disappear.
    static func compose(_ shots: [Shot]) -> Data {
        let canvas = NSSize(width: shots.map(\.size.width).reduce(0, +), height: shots.map(\.size.height).max() ?? 0)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        backdropColor.setFill()
        NSRect(origin: .zero, size: canvas).fill()
        var x: CGFloat = 0
        for shot in shots {
            shot.image.draw(in: NSRect(x: x, y: canvas.height - shot.size.height, width: shot.size.width, height: shot.size.height))
            x += shot.size.width
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
