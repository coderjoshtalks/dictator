import Carbon
import Foundation

/// System-wide key combos (⌃⌥1…8 for transforms, ⌃⌥V to paste the last dictation) via Carbon hot keys,
/// which work in every app and don't leak the keystroke into it.
final class GlobalShortcuts {
    struct Shortcut {
        let keyCode: UInt32
        let label: String
    }

    static let modifiers = UInt32(controlKey | optionKey)
    static let pasteLast = Shortcut(keyCode: UInt32(kVK_ANSI_V), label: "⌃⌥V")
    static let transformSlots: [Shortcut] = [
        (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
        (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"),
    ].map { Shortcut(keyCode: UInt32($0.0), label: "⌃⌥\($0.1)") }

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) {
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, Self.modifiers, EventHotKeyID(signature: OSType(0x4454_4352), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            actions[id] = action
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
