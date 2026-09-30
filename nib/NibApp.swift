// Nib: a small, fast macOS text editor that never loses a keystroke between Macs.
// The scratch window, file windows as native tabs (ED2), and the sync pipeline of §4;
// on test files only until M1 has passed (the safety rule, §8).

import AppKit
import NibText
import SwiftUI

@main
struct NibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        HUDFont.registerBundled()
    }

    var body: some Scene {
        Window("Scratch", id: "scratch") {
            ScratchView(document: Documents.scratch)
        }
        .defaultSize(width: 720, height: 560)
        WindowGroup("File", for: URL.self) { $url in
            if let url {
                FileWindow(url: url)
            } else {
                // The tab bar's + (a window with no file): a new untitled buffer instead (ED3).
                Color.clear.background(WindowConfigurator { window in
                    DispatchQueue.main.async { window.close(); AppDelegate.newUntitled() }
                })
            }
        }
        .defaultSize(width: 760, height: 600)
        WindowGroup("History", id: "history", for: URL.self) { $url in
            HistoryWindow(url: url)
        }
        .defaultSize(width: 820, height: 520)
        .commands { NibCommands() }
        Window("Sync Log", id: "sync-log") {
            SyncLogView()
        }
        .defaultSize(width: 1080, height: 560)
        .commandsRemoved()   // listed in the Window menu by NibCommands, with its shortcut
        Settings { SettingsView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var document: Document { Documents.scratch }
    /// Set by the window when it first appears; reopens it after ⌘W.
    static var openScratchWindow: (() -> Void)?
    /// Opens (or brings forward) a file's window; set by a window once one is up.
    static var openFileWindow: ((URL) -> Void)? {
        didSet { if openFileWindow != nil { let waiting = pendingFiles; pendingFiles = []; waiting.forEach(openFile) } }
    }
    private static var pendingFiles: [URL] = []
    /// Quitting: windows closing now keep their untitled buffers for the next launch (ED3).
    static var terminating = false

    /// File › New, ⌘N (ED3).
    static func newUntitled() {
        guard let url = Untitled.create() else { NSSound.beep(); return }
        openFile(url)
    }

    /// ⌘O, Open Recent, Finder's Open With, the Dock (ED2): the file's window, a tab beside the others.
    static func openFile(_ url: URL) {
        if !Untitled.contains(url) { RecentFiles.shared.add(url) }
        if let document = Documents.existing(for: url) {
            if document === Documents.scratch { showScratch(); return }
            if let window = document.editor.textView.window {
                // Already open: its tab, in front (one buffer per file).
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        if let open = openFileWindow { open(url) } else { pendingFiles.append(url) }
    }

    static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openFile)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Self.openFile)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)   // dark only, always (A17)
        #if DEBUG
        ScenarioFocus.start()   // a scenario's Nib doesn't take the Mac's focus
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let document = Self.document
        // First run (AP5): with no scratch file yet, none is made until the welcome window says so.
        let firstRun = FirstRun.needed
        let waitForChoice = firstRun && !FileManager.default.fileExists(atPath: document.url.path)
        if waitForChoice { document.awaitFirstRun() }
        Task {
            await Document.settlePausedFiles(except: document.url)
            if !waitForChoice { await document.open() }
            ClosedItems.shared.sweep()
            Untitled.restore()   // hot exit (ED3): the untitled buffers from before
            #if DEBUG
            TestHarness.runIfRequested(document)
            #endif
        }
        // Show Scratch (SC2, ⌥Space), Clean Clipboard (PT4, ⌃⌥⌘V) and Append Clipboard to
        // Scratch (SC6, none), from any app, as Settings › General has them.
        GlobalShortcuts.shared.registerAll()
        observeSystem()
        MenuBarController.shared.start()   // the menu bar extra (§5.7), AppKit's own status item
        CLIBridge.start()   // the `nib` command-line tool (AP4)
        // ⌘K opens Go to File too (A6), as ⌘K "Go to…" does in Blit; a menu item takes only one key.
        // ⌘1…⌘9 pick a tab, as in Sublime (§5.12), but for ⌘1-⌘3 with the caret in a conflict block.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  let key = event.charactersIgnoringModifiers, NSApp.keyWindow?.isSheet != true,
                  NSApp.keyWindow?.attachedSheet == nil,
                  !(NSApp.keyWindow?.firstResponder is ShortcutRecorder) else { return event }   // new keys being typed
            let handled = MainActor.assumeIsolated {
                if key == "k" { Self.showPalette(.files, in: nil); return true }
                if let number = Int(key), (1...9).contains(number) { return Self.selectTab(number, in: NSApp.keyWindow) }
                return false
            }
            return handled ? nil : event
        }
        // After SwiftUI has put up the scratch window, so the welcome window is in front of it.
        if firstRun { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { FirstRun.shared.show() } }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Documents.all.forEach { $0.becameActive() }
        ReceiptBook.shared.becameActive()
    }
    func applicationDidResignActive(_ notification: Notification) {
        Documents.all.forEach { $0.resignedActive() }
        ReceiptBook.shared.resignedActive()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showScratch() }
        return true
    }

    /// Quitting: save, upload, hand every file back to iCloud; a watchdog makes sure it ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminating = true
        Task {
            await withTaskGroup(of: Void.self) { group in
                for document in Documents.all { group.addTask { await document.close() } }
            }
            CLIBridge.quitting()   // every file saved: `nib -w` stops waiting
            await ReceiptBook.shared.flush()   // this Mac's receipts, not left for the next launch
            sender.reply(toApplicationShouldTerminate: true)
        }
        // A run-loop timer, not a dispatch block: if quit was asked for from inside a
        // main-queue job, that queue can't drain while AppKit waits, and this still fires.
        let watchdog = Timer(timeInterval: 10, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        return .terminateLater
    }

    static var scratchWindow: NSWindow? { document.editor.textView.window }

    /// ⌘1…⌘9: the window's tab by its number (§5.12); false to leave the keys to the menus, as
    /// with the caret in a conflict block, where ⌘1, ⌘2 and ⌘3 pick a version (§5.4), or a
    /// window with no tabs.
    static func selectTab(_ number: Int, in window: NSWindow?) -> Bool {
        guard let window, !window.isSheet, window.attachedSheet == nil else { return false }
        if number <= 3, Documents.all.first(where: { $0.editor.textView.window === window })?.activeCaretBlock != nil { return false }
        guard let tabs = window.tabGroup?.windows, tabs.count > 1 else { return false }
        guard number <= tabs.count else { NSSound.beep(); return true }
        tabs[number - 1].makeKeyAndOrderFront(nil)
        return true
    }

    /// Quits and opens again, once this one has handed its files back (a new scratch file, SC1).
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        do {
            try task.run()
        } catch {
            NSLog("Nib: couldn't set up the relaunch: \(error)")
        }
        NSApp.terminate(nil)
    }

    /// Settings, as the app menu's item opens it (the menu bar panel has no scene to ask).
    static func openSettings() {
        NSApp.activate()
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let item = menu.items.first(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) else { return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// Go to File or the command palette over the window in front; from a window with no file
    /// (Settings, the Sync Log), over the scratch window.
    static func showPalette(_ kind: PaletteSession.Kind, in document: Document?) {
        let key = NSApp.keyWindow
        if let target = document ?? Documents.all.first(where: { $0.editor.textView.window === key && key != nil }) {
            target.showPalette(kind)
            return
        }
        showScratch()
        DispatchQueue.main.async { Self.document.showPalette(kind) }
    }

    /// Clean Clipboard (PT4): in place, confirmed on screen whichever app is in front.
    static func cleanClipboard() {
        Toast.show(Clipboard.cleanInPlace())
    }

    /// Append Clipboard to Scratch (SC6): confirmed in the scratch window's strip, and on
    /// screen when Nib isn't in front.
    static func appendClipboard() {
        let message = Clipboard.appendToScratch()
        if !NSApp.isActive || scratchWindow?.isKeyWindow != true { Toast.show(message) }
    }

    static func toggleScratch() {
        if NSApp.isActive, scratchWindow?.isKeyWindow == true {
            NSApp.hide(nil)   // back to the app you were in
        } else {
            showScratch()
        }
    }

    static func showScratch() {
        NSApp.activate()
        if let window = scratchWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openScratchWindow?()
        }
    }

    /// The moments that save at once, and the ones that check for newer versions (§4.3, §4.4).
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let save: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, "screens off"),
            (NSWorkspace.sessionDidResignActiveNotification, "user switch"),
        ]
        for (name, reason) in save {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in for document in Documents.all { await document.flush(reason: reason) } }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in for document in Documents.all { await document.fetchLatest(reason: "wake") } }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { _ in
            Task { @MainActor in for document in Documents.all { await document.flush(reason: "screen locked") } }
        }
    }
}

/// The menus (PRD §5.12): File's Open, Open Recent, Save and Revert To, and Conflicts, each
/// acting on the document of the window in front.
struct NibCommands: Commands {
    @FocusedValue(\.nibDocument) private var document
    @AppStorage("editorLineNumbers") private var lineNumbers = true
    @AppStorage("editorInvisibles") private var invisibles = false
    @Environment(\.openWindow) private var openWindow

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
    private func find(_ command: (FindSession) -> Void, else action: Selector) {
        if let document { command(document.editor.find) } else { send(action) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { AppDelegate.newUntitled() }
                .keyboardShortcut("n")
            Button("Open…") { AppDelegate.showOpenPanel() }
                .keyboardShortcut("o")
            OpenRecentMenu()
            // Go to File (KB2, A6): ⌘P as in Sublime; ⌘K too, for the family (AppDelegate).
            Button("Go to File…") { AppDelegate.showPalette(.files, in: document) }.keyboardShortcut("p")
            Divider()
            Button("Reopen Closed File") { ClosedItems.shared.reopenLast() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(ClosedItems.shared.items.isEmpty)
        }
        CommandGroup(replacing: .saveItem) {
            // Everything saves by itself; ⌘S saves and uploads now. An untitled buffer asks
            // where to put it (W3).
            Button(document?.untitled == true ? "Save…" : "Save") {
                guard let document else { return }
                if document.untitled { document.tidyForSave(); Untitled.saveAs(document) } else { Task { await document.saveNow() } }
            }
                .keyboardShortcut("s")
                .disabled(document == nil)
            // Apple's autosave model (ED4, W3): a copy to Save… somewhere, a new name, a new folder.
            Button("Duplicate") { document.map(FileCommands.duplicate) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
            Button("Rename…") { document.map(FileCommands.askRename) }
                .disabled(!FileCommands.canMove(document))
            Button("Move To…") { document.map(FileCommands.askMove) }
                .disabled(!FileCommands.canMove(document))
            if let document { RevertToMenu(document: document) } else { Menu("Revert To") {}.disabled(true) }
        }
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { AppDelegate.showPalette(.commands, in: document) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Menu("Syntax") { SyntaxMenuItems(document: document) }
                .disabled(document == nil)
            // Line numbers and invisibles (ED6), for every window; Settings › Editor too.
            Button(lineNumbers ? "Hide Line Numbers" : "Show Line Numbers") { lineNumbers.toggle() }
            Button(invisibles ? "Hide Invisibles" : "Show Invisibles") { invisibles.toggle() }
        }
        // Nib doesn't print; ⌘P and ⇧⌘P are Sublime's palette keys.
        CommandGroup(replacing: .printItem) {}
        // Edit's clipboard commands (PT1-PT4, SC5, SC6), sent to whatever has focus.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button("Copy") { send(#selector(NSText.copy(_:))) }.keyboardShortcut("c")
            Button("Copy Block") { send(#selector(NibTextView.copyBlock(_:))) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste") { send(#selector(NSText.paste(_:))) }.keyboardShortcut("v")
            Button("Paste Clean") { send(#selector(NSTextView.pasteAsPlainText(_:))) }.keyboardShortcut("v", modifiers: [.command, .option, .shift])
            Button("Delete") { send(#selector(NSText.delete(_:))) }
            Button("Select All") { send(#selector(NSText.selectAll(_:))) }.keyboardShortcut("a")
            Divider()
            // With their global shortcuts, as Settings › General has them.
            Button("Clean Clipboard") { AppDelegate.cleanClipboard() }.globalShortcut(GlobalShortcuts.shared.shortcut(.cleanClipboard))
            Button("Append Clipboard to Scratch") { AppDelegate.appendClipboard() }.globalShortcut(GlobalShortcuts.shared.shortcut(.appendClipboard))
        }
        // Find and replace (ED7, KB1): Nib's own bar, on the Mac's keys and Sublime's. The
        // window's document when there is one (its find field may have focus), else the text
        // view with focus (the merge view's result, or an app not yet in front).
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { find({ $0.open(replace: false) }, else: #selector(NibTextView.showFind(_:))) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { find({ $0.open(replace: true) }, else: #selector(NibTextView.showFindAndReplace(_:))) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { find({ $0.next() }, else: #selector(NibTextView.findNextMatch(_:))) }
                    .keyboardShortcut("g")
                Button("Find Previous") { find({ $0.next(backwards: true) }, else: #selector(NibTextView.findPreviousMatch(_:))) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { find({ $0.useSelection() }, else: #selector(NibTextView.useSelectionForFind(_:))) }
                    .keyboardShortcut("e")
                Divider()
                Button("Replace") { document?.editor.find.replaceCurrent() }.keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(document?.editor.find.shown != true)
                Button("Replace All") { document?.editor.find.replaceAll() }.keyboardShortcut(.return, modifiers: [.control, .option])
                    .disabled(document?.editor.find.shown != true)
            }
        }
        // Sublime's line commands on Sublime's keys (ED6, KB4, §5.12).
        CommandMenu("Text") {
            Button("Indent") { send(#selector(NibTextView.indentLines(_:))) }.keyboardShortcut("]")
            Button("Outdent") { send(#selector(NibTextView.outdentLines(_:))) }.keyboardShortcut("[")
            Button("Toggle Comment") { send(#selector(NibTextView.toggleComment(_:))) }.keyboardShortcut("/")
            Divider()
            Button("Duplicate Line") { send(#selector(NibTextView.duplicateLine(_:))) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Move Line Up") { send(#selector(NibTextView.moveLineUp(_:))) }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Move Line Down") { send(#selector(NibTextView.moveLineDown(_:))) }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Select Line") { send(#selector(NibTextView.selectWholeLine(_:))) }.keyboardShortcut("l")
            Button("Join Lines") { send(#selector(NibTextView.joinLines(_:))) }.keyboardShortcut("j")
            Divider()
            Button("Go to Line…") { document?.goingToLine = true }.keyboardShortcut("g", modifiers: .control).disabled(document == nil)
        }
        CommandMenu("Conflicts") { ConflictMenuItems(document: document) }
        // The first run again (AP5), in place of the Help Book Nib doesn't have.
        CommandGroup(replacing: .help) {
            Button("Welcome to Nib") { FirstRun.shared.show() }
        }
        CommandGroup(before: .windowArrangement) {
            Button("Sync Log") { openWindow(id: "sync-log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

extension View {
    /// A menu item's keys, when they're one of Nib's global shortcuts (which may be none).
    @ViewBuilder
    func globalShortcut(_ shortcut: Shortcut?) -> some View {
        if let shortcut, let key = shortcut.keyEquivalent {
            keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            self
        }
    }
}

/// File › Open Recent, from the system's list (ED2).
struct OpenRecentMenu: View {
    var body: some View {
        Menu("Open Recent") {
            ForEach(RecentFiles.shared.urls, id: \.self) { url in
                Button(url.lastPathComponent) { AppDelegate.openFile(url) }
            }
            if !RecentFiles.shared.urls.isEmpty { Divider() }
            Button("Clear Menu") { RecentFiles.shared.clear() }
                .disabled(RecentFiles.shared.urls.isEmpty)
        }
    }
}

@MainActor
@Observable
final class RecentFiles {
    static let shared = RecentFiles()
    private(set) var urls: [URL]
    private let key = "recentFiles"

    /// Nib's own list, not the system's: reading that waits on a helper that can stop answering,
    /// and did (a launch at 21:50 stuck for good in -[NSDocumentController recentDocumentURLs],
    /// the File menu asking for it). The system still hears of each file, for the Dock's menu.
    private init() {
        urls = (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        urls.insert(url, at: 0)
        if urls.count > 10 { urls.removeLast(urls.count - 10) }
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }

    /// Moved or renamed (ED4): its old path isn't a file any more.
    func remove(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The Conflicts menu (PRD §5.4, §5.12): with the caret in a block, ⌘1 uses the first
/// version, ⌘2 the second, ⌘3 keeps both; ⌥⌘↓ and ⌥⌘↑ go between blocks; Resolve… opens
/// the merge view for more than three. In the merge view, they act on its result.
struct ConflictMenuItems: View {
    let document: Document?

    var body: some View {
        let block = document?.activeCaretBlock
        let count = document?.activeBlockCount ?? 0
        Button(block.map { "Use \($0.firstLabel)" } ?? "Use the First Version") { document?.resolveBlock(.first) }
            .keyboardShortcut("1")
            .disabled(block == nil)
        Button(block.map { "Use \($0.secondLabel)" } ?? "Use the Second Version") { document?.resolveBlock(.second) }
            .keyboardShortcut("2")
            .disabled(block == nil)
        Button("Keep Both") { document?.resolveBlock(.both) }
            .keyboardShortcut("3")
            .disabled(block == nil)
        Divider()
        Button("Next Conflict") { document?.goToBlock(forward: true) }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(count == 0)
        Button("Previous Conflict") { document?.goToBlock(forward: false) }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(count == 0)
        Button("Resolve…") { document?.resolveConflicts() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(document?.blocks.isEmpty != false || document?.merge != nil)
    }
}
