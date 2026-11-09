import AppKit
import Carbon

/// A system-wide hotkey (Carbon `RegisterEventHotKey`; needs no extra permissions).
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Distinguishes this hotkey from peek's others (each instance handles only its own).
    private let id: UInt32
    private static var nextID: UInt32 = 1

    init() {
        id = Self.nextID
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.signature == OSType(0x7065_656B), pressed.id == me.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { me.onPress?() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private(set) var current: Shortcut?

    /// Registers `shortcut`, replacing the current one. If macOS refuses it (e.g. another app
    /// owns it), the previous shortcut stays registered and this returns false.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        if shortcut == current, hotKeyRef != nil { return true }
        let previous = current
        unregister()
        let f = shortcut.modifierFlags
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        let id = EventHotKeyID(signature: OSType(0x7065_656B), id: id)  // 'peek'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            NSLog("peek: hotkey registration failed (\(status))")
            hotKeyRef = nil
            if let previous, previous != shortcut { register(previous) }
            return false
        }
        current = shortcut
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
