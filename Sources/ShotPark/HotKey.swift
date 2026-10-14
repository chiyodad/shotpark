import Carbon
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// Each instance has its own id; the handler ignores presses that belong to another HotKey.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    let id: UInt32
    let callback: () -> Void
    /// false when the system or another app already owns the combination.
    private(set) var isRegistered = false

    init(id: UInt32 = 1, keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.id = id
        self.callback = callback

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hk = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.id == hk.id else { return OSStatus(eventNotHandledErr) } // someone else's hotkey
            DispatchQueue.main.async { hk.callback() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5353_4854), id: id) // 'SSHT'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr && hotKeyRef != nil
        if !isRegistered { NSLog("ShotPark: RegisterEventHotKey failed (\(status)) for keyCode \(keyCode)") }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
