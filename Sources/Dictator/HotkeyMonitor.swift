import AppKit

enum Hotkey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand
    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "fn (🌐)"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        }
    }
}

/// Turns presses of a single modifier key into dictation gestures:
///  - hold, speak, release        → push-to-talk
///  - double-tap                  → hands-free; tap again to finish
///  - Esc                         → cancel
///  - pressing another key while holding (a normal shortcut) → cancel
final class HotkeyMonitor {
    enum Action { case start, finish, cancel, handsFree }

    var hotkey: Hotkey = .fn
    var onAction: ((Action) -> Void)?

    private var monitors: [Any] = []
    private var receivedFirstEvent = false
    private var isDown = false
    private var downAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var active = false
    private var handsFree = false

    private let holdThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.45

    /// Listens with NSEvent monitors (global for other apps, local for Dictator's own windows).
    /// A CGEventTap was tried in 0.3.0 and destabilised the Swift runtime's main-thread bookkeeping (crashes inside
    /// SwiftUI), so it is intentionally not used.
    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            if !self.receivedFirstEvent {
                self.receivedFirstEvent = true
                Log.write("hotkey listener is receiving key events")
            }
            self.flagsChanged(event)
        }
        let keys: (NSEvent) -> Void = { [weak self] in self?.keyDown($0) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
        Log.write("hotkey listener: NSEvent monitors (\(monitors.count))")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// A hands-free dictation started from the on-screen bar: the next press of the hotkey finishes it.
    func beginHandsFree() {
        active = true
        handsFree = true
    }

    /// Called by the controller when a session ends for reasons of its own (e.g. an error).
    func reset() {
        active = false
        handsFree = false
    }

    private func flagsChanged(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let pressed = event.modifierFlags.contains(hotkey.flag)
        guard pressed != isDown else { return }
        isDown = pressed
        let now = Date()

        if pressed {
            Log.write("hotkey down (\(hotkey.rawValue))")
            downAt = now
            if handsFree {
                handsFree = false
                active = false
                onAction?(.finish)
            } else if !active {
                active = true
                onAction?(.start)
            }
            return
        }

        guard active, !handsFree else { return }
        if now.timeIntervalSince(downAt) >= holdThreshold {
            active = false
            onAction?(.finish)
        } else if now.timeIntervalSince(lastTapAt) <= doubleTapWindow {
            handsFree = true                 // second quick tap: keep listening
            lastTapAt = .distantPast
            onAction?(.handsFree)
        } else {
            active = false                   // a lone quick tap is not a dictation
            lastTapAt = now
            onAction?(.cancel)
        }
    }

    private func keyDown(_ event: NSEvent) {
        guard active else { return }
        if event.keyCode == 53 || (event.keyCode == 51 && handsFree) {   // Esc (or Delete while hands-free)
            reset()
            onAction?(.cancel)
        } else if isDown && !handsFree {     // hotkey used as part of a shortcut
            reset()
            onAction?(.cancel)
        }
    }
}
