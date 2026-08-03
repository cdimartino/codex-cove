import AppKit
import ApplicationServices

@MainActor
final class CoveKeyboardShortcutBroker {
    var onToggleOverlay: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    var onJumpToTerminal: ((String) -> Void)?

    private var monitor: Any?
    private var enabled = false

    func configure(enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        enabled = false
    }

    private func start() {
        guard !enabled else { return }
        guard AXIsProcessTrusted() else { return }
        enabled = true
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            self.handle(event: event)
        }
    }

    private func handle(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains([.command, .shift]) else { return }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "o":
            onToggleOverlay?()
        case "e":
            onToggleExpanded?()
        case "t":
            onJumpToTerminal?(NSHomeDirectory())
        default:
            break
        }
    }
}
