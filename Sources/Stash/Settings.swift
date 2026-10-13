import AppKit
import ServiceManagement

@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("StashSettingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: ["showInDock": false, "drawingShortcut": true])
    }

    var triggerKey: TriggerKey {
        get { TriggerKey(rawValue: defaults.string(forKey: "triggerKey") ?? "") ?? .shift }
        set { defaults.set(newValue.rawValue, forKey: "triggerKey"); changed() }
    }

    var drawingShortcut: Bool {
        get { defaults.bool(forKey: "drawingShortcut") && triggerKey != .command }
        set { defaults.set(newValue, forKey: "drawingShortcut"); changed() }
    }

    var showInDock: Bool {
        get { defaults.bool(forKey: "showInDock") }
        set { defaults.set(newValue, forKey: "showInDock"); changed() }
    }

    var keepOnTop: Bool {
        get { defaults.bool(forKey: "keepOnTop") }
        set { defaults.set(newValue, forKey: "keepOnTop"); changed() }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
            changed()
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let keyPopup = NSPopUpButton()
    private let drawingCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let dockCheck = NSButton(checkboxWithTitle: "Show Stash in the Dock and ⌘-Tab switcher", target: nil, action: nil)
    private let topCheck = NSButton(checkboxWithTitle: "Keep the Stash window on top of other windows", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Open Stash when you log in", target: nil, action: nil)
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for key in TriggerKey.allCases {
            keyPopup.addItem(withTitle: "Double-tap \(key.symbol) \(key.name)")
            keyPopup.lastItem?.representedObject = key.rawValue
        }
        for control in [keyPopup, drawingCheck, dockCheck, topCheck, loginCheck, accessButton] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        accessLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [label("Capture:"), keyPopup],
            [NSGridCell.emptyContentView, hint("Select text anywhere, then double-tap to save it. With nothing selected, it opens Stash.")],
            [label("Drawing:"), drawingCheck],
            [label("Window:"), dockCheck],
            [NSGridCell.emptyContentView, topCheck],
            [label("Startup:"), loginCheck],
            [label("Access:"), accessLabel],
            [NSGridCell.emptyContentView, accessButton],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.row(at: 2).topPadding = 8
        grid.row(at: 3).topPadding = 8
        grid.row(at: 5).topPadding = 8
        grid.row(at: 6).topPadding = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        window.contentView = content
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.level = .floating
        showWindow(nil)
    }

    private func refresh() {
        let settings = Settings.shared
        keyPopup.selectItem(at: TriggerKey.allCases.firstIndex(of: settings.triggerKey) ?? 0)
        drawingCheck.title = "⌘ + double-tap \(settings.triggerKey.symbol) opens the drawing editor"
        drawingCheck.state = settings.drawingShortcut ? .on : .off
        drawingCheck.isEnabled = settings.triggerKey != .command
        dockCheck.state = settings.showInDock ? .on : .off
        topCheck.state = settings.keepOnTop ? .on : .off
        loginCheck.state = settings.launchAtLogin ? .on : .off
        accessLabel.stringValue = SelectionReader.isTrusted ? "Accessibility access granted" : "Accessibility access needed to capture"
        accessButton.isHidden = SelectionReader.isTrusted
    }

    @objc private func controlChanged(_ sender: NSControl) {
        let settings = Settings.shared
        switch sender {
        case keyPopup:
            settings.triggerKey = TriggerKey(rawValue: keyPopup.selectedItem?.representedObject as? String ?? "") ?? .shift
        case drawingCheck: settings.drawingShortcut = drawingCheck.state == .on
        case dockCheck: settings.showInDock = dockCheck.state == .on
        case topCheck: settings.keepOnTop = topCheck.state == .on
        case loginCheck: settings.launchAtLogin = loginCheck.state == .on
        case accessButton:
            SelectionReader.promptForTrust()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default: break
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func hint(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 320
        return field
    }
}
