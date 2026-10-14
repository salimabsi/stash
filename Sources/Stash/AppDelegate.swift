import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = Store()
    private lazy var panel = PanelController(store: store)
    private let captureToast = CaptureToast()
    private let monitor = DoubleTapMonitor()
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        setUpMainMenu()
        setUpStatusItem()
        panel.onOpenSettings = { SettingsWindowController.shared.present() }
        if CommandLine.arguments.contains("--enable-launch-at-login") {
            Settings.shared.launchAtLogin = true
        }

        monitor.onCapture = { [weak self] in Task { @MainActor in self?.handleCapture() } }
        monitor.onDraw = { [weak self] in Task { @MainActor in self?.panel.openDrawing() } }
        applyMonitorSettings()
        applyTheme()
        monitor.start()

        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyActivationPolicy()
                self?.applyMonitorSettings()
                self?.applyTheme()
            }
        }

        if !SelectionReader.isTrusted {
            SelectionReader.promptForTrust()
            waitForTrust()
        }
        // Stash runs in the background like a menu bar utility; only a brand-new install
        // opens the window, so the first launch isn't invisible.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            panel.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    private func applyTheme() {
        NSApp.appearance = Settings.shared.theme.appearance
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = Settings.shared.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private func applyMonitorSettings() {
        monitor.key = Settings.shared.triggerKey
        monitor.drawingEnabled = Settings.shared.drawingShortcut
    }

    // MARK: - Capture

    private func handleCapture() {
        if NSApp.isActive {
            panel.toggle()
            return
        }
        guard SelectionReader.isTrusted else {
            NSApp.unhideWithoutActivation()
            captureToast.show(title: "Stash can’t read your selection", detail: "Turn on Stash in Privacy & Security → Accessibility", style: .warning)
            return
        }
        SelectionReader.read { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                guard let text, let id = self.store.add(text) else {
                    self.panel.show()
                    return
                }
                self.flashStatusIcon()
                if self.panel.isVisible {
                    self.panel.reveal(id)
                } else {
                    let section = self.store.section(containing: id)?.title ?? ""
                    let plain = Markdown.render(text).string
                    let preview = plain.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    NSApp.unhideWithoutActivation()
                    self.captureToast.show(title: section.isEmpty ? "Saved to Stash" : "Saved to \(section)", detail: preview)
                }
            }
        }
    }

    private func waitForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard SelectionReader.isTrusted else { return }
                timer.invalidate()
                self?.trustTimer = nil
                self?.monitor.start()
            }
        }
    }

    // MARK: - Menus

    private func setUpMainMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "Stash")
        app.addItem(MenuAction("About Stash", modifiers: []) { NSApp.orderFrontStandardAboutPanel(nil) })
        app.addItem(.separator())
        app.addItem(MenuAction("Settings…", key: ",") { SettingsWindowController.shared.present() })
        app.addItem(MenuAction("Reveal Notes in Finder", modifiers: []) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.store.fileURL])
        })
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Stash", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: "Quit Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(app))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        main.addItem(submenu(edit))

        let view = NSMenu(title: "View")
        view.delegate = self
        main.addItem(submenu(view))

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "View" else { return }
        menu.removeAllItems()
        for item in panel.makeMenu().items where item.title != "Quit Stash" && item.title != "Settings…" {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Logo.menuBarImage
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func flashStatusIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.statusItem.button?.image = Logo.menuBarImage
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = panel.makeMenu()
            menu.delegate = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            panel.toggle()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === statusItem.menu { statusItem.menu = nil }
    }
}
