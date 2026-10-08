// A global shortcut's keys, changed by clicking and pressing new ones (PRD SC2, §5.8, §5.9):
// Escape keeps the old keys, Delete clears them. While it listens none of Nib's global
// shortcuts are registered, so pressing ⌥Space reaches the field instead of hiding Nib.
// Another app's global shortcut still goes to that app, and macOS's own (⌘Space) to macOS.

import AppKit
import SwiftUI

/// A shortcut's row: its name, the field, a way back to Nib's own keys, and what stands in
/// the way of the keys if anything does.
struct ShortcutRow: View {
    let action: GlobalShortcuts.Action

    var body: some View {
        let shortcuts = GlobalShortcuts.shared
        let keys = shortcuts.shortcut(action)
        LabeledContent(action.title) {
            HStack(spacing: 6) {
                if keys != action.standard {
                    Button { shortcuts.reset(action) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(action.standard.map { "Back to \($0.description)" } ?? "Back to none")
                        .accessibilityLabel(action.standard.map { "Back to \($0.spoken)" } ?? "Back to none")
                }
                ShortcutField(action: action, keys: keys)
                    .frame(width: 150, height: 22)
            }
        }
        if let warning = shortcuts.warnings[action] {
            Label { Text(warning).font(.caption).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.failure)
            }
        }
    }
}

struct ShortcutField: NSViewRepresentable {
    let action: GlobalShortcuts.Action
    /// What it shows; passed in so the field redraws when the keys change.
    let keys: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorder { ShortcutRecorder(action: action) }
    func updateNSView(_ view: ShortcutRecorder, context: Context) { view.refresh() }
}

final class ShortcutRecorder: NSButton {
    let shortcutAction: GlobalShortcuts.Action
    private(set) var recording = false {
        didSet { refresh() }
    }

    init(action: GlobalShortcuts.Action) {
        shortcutAction = action
        super.init(frame: .zero)
        bezelStyle = .push
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(clicked)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func clicked() {
        recording ? stop() : start()
    }

    func start() {
        recording = true
        GlobalShortcuts.shared.suspend()
        window?.makeFirstResponder(self)
    }

    func stop() {
        guard recording else { return }
        recording = false
        GlobalShortcuts.shared.resume()
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        stop()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer); resignObserver = nil }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Its window no longer key (another app in front): the shortcuts come back, or ⌥Space
    /// would stay off with the field still listening behind.
    private var resignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Keys with ⌘ come here before the menus do: while listening, they're the new keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case 53: stop(); return   // Escape: keep the keys
            case 51, 117: stop(); GlobalShortcuts.shared.set(nil, for: shortcutAction); refresh(); return   // Delete: none
            case 48: stop(); super.keyDown(with: event); return   // Tab: on to the next control
            default: break
            }
        }
        guard let shortcut = Shortcut(event: event) else { NSSound.beep(); return }   // needs ⌘, ⌃ or ⌥
        // Stopped first: stopping registers every shortcut again, which clears the warnings, and a
        // refusal set before it was wiped as it was made (the QA review's F24).
        stop()
        GlobalShortcuts.shared.set(shortcut, for: shortcutAction)
        refresh()   // stopping drew the keys as they were
    }

    func refresh() {
        let keys = GlobalShortcuts.shared.shortcut(shortcutAction)
        title = recording ? "Type the keys…" : (keys?.description ?? "None")
        setAccessibilityLabel("\(shortcutAction.title) shortcut")
        setAccessibilityValue(recording ? "Listening for new keys" : (keys?.spoken ?? "None"))
        setAccessibilityHelp("Press to change, then type the new keys. Escape keeps them, Delete clears them.")
    }
}
