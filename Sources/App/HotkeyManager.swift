import BouncerCore
import Carbon.HIToolbox

/// One system-wide shortcut via Carbon's RegisterEventHotKey, which needs no
/// Accessibility or Input Monitoring permission.
@MainActor
final class HotkeyManager {
    var onPress: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x424E_4352 // 'BNCR'
    private static weak var current: HotkeyManager?

    func register(_ chord: HotkeyChord?) {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard let chord else { return }
        installHandlerIfNeeded()
        var modifiers: UInt32 = 0
        if chord.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if chord.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if chord.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if chord.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(chord.keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            NSLog("Bouncer couldn't register hotkey \(chord) (\(status)); another app may own it.")
            reference = nil
        }
    }

    private func installHandlerIfNeeded() {
        Self.current = self
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { HotkeyManager.current?.onPress?() }
            return noErr
        }, 1, &eventType, nil, &handler)
    }
}
