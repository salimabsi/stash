import AppKit

enum TriggerKey: String, CaseIterable {
    case shift, option, control, command

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        }
    }

    var keyCodes: Set<UInt16> {
        switch self {
        case .shift: [56, 60]
        case .option: [58, 61]
        case .control: [59, 62]
        case .command: [55, 54]
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        }
    }

    var name: String { rawValue.capitalized }
}

/// Fires when the trigger key is tapped twice quickly on its own, or with ⌘ held for
/// the drawing shortcut. Any other key in between cancels the sequence, so typing
/// capitals like "AB" never triggers it.
final class DoubleTapMonitor {
    var key: TriggerKey = .shift { didSet { reset() } }
    var drawingEnabled = true
    var onCapture: () -> Void = {}
    var onDraw: () -> Void = {}

    private let maxTapDuration: TimeInterval = 0.3
    private let maxGapBetweenTaps: TimeInterval = 0.4

    private var monitors: [Any] = []
    private var keyDownAt: TimeInterval?
    private var heldWithTap: NSEvent.ModifierFlags = []
    private var lastTap: (at: TimeInterval, held: NSEvent.ModifierFlags)?

    /// Global monitors only receive events once Accessibility is granted, and do not
    /// start receiving them retroactively, so this is called again after the grant.
    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged, key.keyCodes.contains(event.keyCode) else { return reset() }

        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let others = modifiers.subtracting(key.flag)
        let allowedHeld: NSEvent.ModifierFlags = drawingEnabled && key != .command ? [.command] : []
        guard allowedHeld.isSuperset(of: others) else { return reset() }

        if modifiers.contains(key.flag) {
            keyDownAt = event.timestamp
            heldWithTap = others
        } else if let downAt = keyDownAt, others == heldWithTap {
            keyDownAt = nil
            guard event.timestamp - downAt < maxTapDuration else { return reset() }
            if let last = lastTap, last.held == others, event.timestamp - last.at < maxGapBetweenTaps {
                lastTap = nil
                others.contains(.command) ? onDraw() : onCapture()
            } else {
                lastTap = (event.timestamp, others)
            }
        } else {
            reset()
        }
    }

    private func reset() {
        keyDownAt = nil
        lastTap = nil
    }
}
