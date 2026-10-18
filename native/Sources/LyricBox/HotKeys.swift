import Carbon

/// Global shortcuts through Carbon hot keys (works without Accessibility permission).
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeys.handlers[hk.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4C59_4258), id: id) // "LYBX"
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }
}
