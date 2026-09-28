// Global shortcuts (PRD SC2, §6.3): Carbon's RegisterEventHotKey, which needs no
// Accessibility permission. About a hundred lines instead of a dependency (T7);
// moves into the shared package's AppShell in M2 (§7).

import Carbon.HIToolbox

@MainActor
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var references: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false

    /// Registers `keyCode` with Carbon `modifiers` (optionKey, cmdKey, …). False when
    /// another app already holds the combination.
    @discardableResult
    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandler()
        if let old = references.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6E69_6221), id: id)   // 'nib!'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        actions[id] = action
        return true
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
