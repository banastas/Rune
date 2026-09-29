// Global shortcuts (PRD SC2, PT4, SC6, §5.8, §6.3): Carbon's RegisterEventHotKey, which needs
// no Accessibility permission. About a hundred lines instead of a dependency (T7); moves into
// the shared package's AppShell (§7). Each can be changed in Settings › General and in the
// first run (AP5), which say when the keys won't work: another app holds them, macOS keeps
// them, or a launcher that's running uses them by default.

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
enum HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var references: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false

    /// Registers `keyCode` with Carbon `modifiers` (optionKey, cmdKey, …), exclusively: while
    /// Nib holds the keys no other app can take them exclusively, and when another app took
    /// them exclusively first this returns `eventHotKeyExistsErr`. (An app that registered them
    /// without asking for that isn't reported: Carbon doesn't say.)
    @discardableResult
    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> OSStatus {
        installHandler()
        unregister(id: id)
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x6E69_6221), id: id)   // 'nib!'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return status == noErr ? OSStatus(eventInternalErr) : status }
        references[id] = reference
        actions[id] = action
        return noErr
    }

    static func unregister(id: UInt32) {
        if let old = references.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        actions[id] = nil
    }

    static var registered: Set<UInt32> { Set(references.keys) }

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

    /// Whether macOS keeps these keys for itself and has them turned on (Spotlight's ⌘Space,
    /// the input sources' ⌃Space, Mission Control's…): it gets them before any app does.
    static func usedByMacOS(_ shortcut: Shortcut) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let items = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return items.contains { item in
            (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (item[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == shortcut.keyCode
                && (item[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & Shortcut.modifierMask } == shortcut.modifiers
        }
    }
}

/// A key and its modifiers, in Carbon's terms, as RegisterEventHotKey and macOS's own
/// shortcuts give them: the key's place on the keyboard, whatever the layout prints on it.
struct Shortcut: Hashable, Sendable {
    var keyCode: UInt32
    /// cmdKey, optionKey, controlKey and shiftKey.
    var modifiers: UInt32

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// From a key press, if it can be a global shortcut: a key with ⌘, ⌃ or ⌥ (⇧ alone would
    /// take a capital letter from every app), or a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = UInt32(event.keyCode)
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.keys.contains(Int(code)) else { return nil }
        self.init(keyCode: code, modifiers: carbon)
    }

    /// As stored in the defaults: "49:2048".
    init?(stored: String) {
        let parts = stored.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    var stored: String { "\(keyCode):\(modifiers)" }

    /// "⌃⌥⌘V", as menus write it.
    var description: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// For VoiceOver: "Control Option Command V".
    var spoken: String {
        let names = [(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1)
        return (names + [Self.spokenNames[Int(keyCode)] ?? keyName]).joined(separator: " ")
    }

    var keyName: String {
        if let name = Self.names[Int(keyCode)] ?? Self.functionKeys[Int(keyCode)].map({ "F\($0)" }) { return name }
        return Self.character(for: keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// For a menu item showing the same keys, when SwiftUI can show them.
    var keyEquivalent: KeyEquivalent? {
        let special: [Int: KeyEquivalent] = [
            kVK_Space: .space, kVK_Return: .return, kVK_Tab: .tab, kVK_Delete: .delete, kVK_ForwardDelete: .deleteForward,
            kVK_Escape: .escape, kVK_LeftArrow: .leftArrow, kVK_RightArrow: .rightArrow, kVK_UpArrow: .upArrow,
            kVK_DownArrow: .downArrow, kVK_Home: .home, kVK_End: .end, kVK_PageUp: .pageUp, kVK_PageDown: .pageDown,
        ]
        if let key = special[Int(keyCode)] { return key }
        if let number = Self.functionKeys[Int(keyCode)], let scalar = UnicodeScalar(UInt32(NSF1FunctionKey + number - 1)) {
            return KeyEquivalent(Character(scalar))
        }
        guard let text = Self.character(for: keyCode), text.count == 1, let character = text.lowercased().first else { return nil }
        return KeyEquivalent(character)
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]
    private static let spokenNames: [Int: String] = [
        kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Escape",
        kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow", kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_ANSI_KeypadEnter: "Enter",
    ]
    /// F1-F20 by key code.
    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    /// What the key types on the keyboard layout in use, with no modifiers ("v").
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : text
    }
}

/// Nib's global shortcuts, as set in Settings › General (or the defaults), registered with
/// Carbon, each with what stands in its way if anything does.
@MainActor
@Observable
final class GlobalShortcuts {
    enum Action: String, CaseIterable, Identifiable {
        case showScratch, cleanClipboard, appendClipboard

        var id: String { rawValue }
        var title: String {
            switch self {
            case .showScratch: "Show Scratch"
            case .cleanClipboard: "Clean Clipboard"
            case .appendClipboard: "Append Clipboard to Scratch"
            }
        }
        /// ⌥Space (SC2: ⌃Space and ⌃⌥Space are macOS's input-source keys) and ⌃⌥⌘V (PT4);
        /// Append has none until one is chosen (SC6).
        var standard: Shortcut? {
            switch self {
            case .showScratch: Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
            case .cleanClipboard: Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | cmdKey))
            case .appendClipboard: nil
            }
        }
        fileprivate var hotKeyID: UInt32 {
            switch self {
            case .showScratch: 1
            case .cleanClipboard: 2
            case .appendClipboard: 3
            }
        }
        fileprivate var key: String { "shortcut." + rawValue }
        @MainActor fileprivate func perform() {
            switch self {
            case .showScratch: AppDelegate.toggleScratch()
            case .cleanClipboard: AppDelegate.cleanClipboard()
            case .appendClipboard: AppDelegate.appendClipboard()
            }
        }
    }

    static let shared = GlobalShortcuts()

    /// Why an action's keys don't work, or may not, in a sentence for Settings and the first run.
    private(set) var warnings: [Action: String] = [:]
    /// While a shortcut field listens for new keys, none are registered, so pressing Nib's own
    /// keys reaches the field rather than showing the scratch window.
    private(set) var suspended = false
    /// Changes to the stored keys, for views to redraw.
    private(set) var changes = 0

    /// Launchers whose usual key is ⌥Space. If one's running, it may still hold it.
    private static let launchers = [("com.raycast.macos", "Raycast"), ("com.runningwithcrayons.Alfred", "Alfred")]

    func shortcut(_ action: Action) -> Shortcut? {
        _ = changes
        guard let stored = UserDefaults.standard.string(forKey: action.key) else { return action.standard }
        return Shortcut(stored: stored)   // "" is none
    }

    /// New keys for an action, or none. Keys another of Nib's actions has are refused.
    func set(_ shortcut: Shortcut?, for action: Action) {
        if let shortcut, let other = Action.allCases.first(where: { $0 != action && self.shortcut($0) == shortcut }) {
            warnings[action] = "\(other.title) already uses \(shortcut.description). These keys stay \(self.shortcut(action)?.description ?? "unset")."
            return
        }
        UserDefaults.standard.set(shortcut?.stored ?? "", forKey: action.key)
        changes += 1
        register(action)
    }

    /// Back to Nib's own keys.
    func reset(_ action: Action) {
        UserDefaults.standard.removeObject(forKey: action.key)
        changes += 1
        register(action)
    }

    func registerAll() {
        Action.allCases.forEach(register)
    }

    func suspend() {
        suspended = true
        Action.allCases.forEach { HotKey.unregister(id: $0.hotKeyID) }
    }

    func resume() {
        suspended = false
        registerAll()
    }

    private func register(_ action: Action) {
        warnings[action] = nil
        guard !suspended else { return }
        guard let shortcut = shortcut(action) else { HotKey.unregister(id: action.hotKeyID); return }
        let keys = shortcut.description
        let status = HotKey.register(id: action.hotKeyID, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { action.perform() }
        if status == eventHotKeyExistsErr {
            warnings[action] = "Another app holds \(keys), so Nib can't use it. Choose other keys, or free them in that app."
        } else if status != noErr {
            warnings[action] = "Nib couldn't use \(keys) (Carbon error \(status)). Choose other keys."
        } else if HotKey.usedByMacOS(shortcut) {
            warnings[action] = "macOS uses \(keys) itself (System Settings › Keyboard › Keyboard Shortcuts), so it won't reach Nib. Choose other keys, or turn that one off there."
        } else if shortcut == Action.showScratch.standard,
                  let (_, name) = Self.launchers.first(where: { launcher in NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == launcher.0 } }) {
            warnings[action] = "\(name) is running, and \(keys) is its usual key. If \(name) still uses it, the two clash: change the keys here or in \(name)."
        }
        if let warning = warnings[action] { NSLog("Nib: \(action.title): \(warning)") }
    }
}
