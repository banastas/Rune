// Nib: a small, fast macOS text editor that never loses a keystroke between Macs.
// The scratch window, file windows as native tabs (ED2), and the sync pipeline of §4; in a
// test run, on test files only (the safety rule, §8).

import AppKit
import NibSync
import NibText
import SwiftUI

@main
struct NibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        AppDelegate.mark("the app starting")
        // Before any window is made: a scenario's windows keep their places out of the user's defaults.
        if NibPaths.isScenario { ScenarioWindows.keepFramesOut() }
        #endif
        HUDFont.registerBundled()
        #if DEBUG
        AppDelegate.mark("fonts registered")
        #endif
    }

    var body: some Scene {
        #if DEBUG
        let _ = AppDelegate.mark("scenes")
        #endif
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
        Window("About Rune", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .commandsRemoved()
        // Opened from About Nib: the third-party notices Nib ships (DS3).
        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 820, height: 640)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var document: Document { Documents.scratch }
    /// Set by the window when it first appears; reopens it after ⌘W.
    static var openScratchWindow: (() -> Void)?
    /// Opens (or brings forward) a file's window; set by a window once one is up.
    static var openFileWindow: ((URL) -> Void)? {
        didSet { if openFileWindow != nil { let waiting = pendingFiles; pendingFiles = []; waiting.forEach { openFile($0) } } }
    }
    private static var pendingFiles: [URL] = []
    /// Quitting: windows closing now keep their untitled buffers for the next launch (ED3).
    static var terminating = false
    #if DEBUG
    /// Where a launch's time went, for §6.5's cold launch (the scenarios' first line): the phases,
    /// and when the scratch window came up and when its text was in it and editable.
    static var launchPhases: [(name: String, seconds: Double)] = []
    static var launchMoments: (window: Date?, text: Date?) = (nil, nil)
    /// The scratch file's open done: held, and iCloud asked about it (`reopen-return`).
    static var scratchOpenedAt: Date?
    /// Moments before "launched", from the process's start.
    nonisolated(unsafe) static var launchMarks: [(name: String, time: Date)] = []
    nonisolated static func mark(_ name: String) { launchMarks.append((name, Date())) }
    #endif

    /// File › New (⌘N) and New Tab (⌘T), ED3: an empty file, a tab in the window in front (the
    /// scratch file's too, A5), in Markdown until another syntax is picked (the user's call,
    /// 2026-10-02).
    static func newUntitled() {
        // A new buffer is new text: not once the trial has ended (DS4).
        guard !LicenseManager.shared.typingLocked else { Toast.show(LicenseManager.shared.refusedHUD, for: 4); return }
        guard let url = Untitled.create() else {   // said, not only a beep (F72)
            Toast.show("✕ COULDN'T MAKE A NEW BUFFER · \(Untitled.lastError.map(ErrorWords.hud) ?? "RUNE'S UNTITLED FOLDER")", for: 4)
            return
        }
        NibDefaults.store.set(SyntaxPick.language(.markdown).stored, forKey: "syntax:" + url.path)
        FileWindow.tabHost = NSApp.keyWindow ?? NSApp.mainWindow
        openFile(url)
    }

    enum TabKey: Equatable { case goToFile, tab(Int) }

    /// ⌘K and ⌘1…⌘9 from a key press: ⌘ and nothing else, Caps Lock on or off, and a digit by its
    /// place on the keyboard, whatever the layout prints there. Caps Lock turned both off, and on
    /// AZERTY ⌘1 is "&" (the QA review's F29, 2026-10-07).
    nonisolated static func tabKey(_ event: NSEvent) -> TabKey? {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return nil }
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]   // kVK_ANSI_1…9
        if let number = digits[event.keyCode] { return .tab(number) }
        if event.charactersIgnoringModifiers?.lowercased() == "k" { return .goToFile }
        return nil
    }

    /// A file from a list (Open Recent, Go to File): opened if it's still there; if not, said so and
    /// taken off Open Recent, not made again, empty (the QA review's F3).
    static func openListed(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) || Documents.existing(for: url) != nil else {
            RecentFiles.shared.remove(url)
            Toast.show("✕ “\(url.lastPathComponent.uppercased())” ISN'T THERE ANY MORE · TAKEN OFF OPEN RECENT", for: 4)
            return
        }
        openFile(url)
    }

    /// ⌘O, Open Recent, Finder's Open With, the Dock (ED2): the file's window, a tab beside the
    /// others. False when it wasn't opened: over 100 MB, and the question answered Cancel (ED9).
    /// `reopening`: a tab from the last quit (`OpenTabs`): not asked about again, and Open Recent
    /// left in the order the user made.
    @discardableResult
    static func openFile(_ url: URL, reopening: Bool = false) -> Bool {
        guard Documents.existing(for: url) != nil || Untitled.contains(url) || reopening || mayOpenLarge(url) else { return false }
        if !Untitled.contains(url), !reopening { RecentFiles.shared.add(url) }
        if let document = Documents.existing(for: url) {
            if document === Documents.scratch { showScratch(); return true }
            if let window = document.editor.textView.window {
                // Already open: its tab, in front (one buffer per file).
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        FileWindow.noteAsked(url)   // its tab after the ones asked for before it
        if let open = openFileWindow { open(url) } else { pendingFiles.append(url) }
        return true
    }

    /// ED9: a file over 100 MB opens only once asked (a decision, V8). Nib's own untitled
    /// buffers aren't asked about: the user made them.
    static let askAbove: Int64 = 100_000_000

    static func mayOpenLarge(_ url: URL) -> Bool {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size > askAbove else { return true }
        let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        #if DEBUG
        if let answer = TestHarness.largeFileAnswer {
            TestHarness.largeFileAsked.append(url.lastPathComponent)
            return answer
        }
        #endif
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” is \(shown). Open it?"
        // Saves write only what differs from the file since 2026-10-02 (the QA review's F18).
        alert.informativeText = "Rune opens files this big without highlighting, and History keeps only the versions it opened and closed with. They're slower to open and to save, and in iCloud Drive each save is uploaded whole."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// File › Save, and the strip's Save Now: ⌘S's tidying, then saved and uploaded now; an
    /// untitled buffer asks where to put it (W3).
    static func save(_ document: Document) {
        if document.untitled { document.tidyForSave(); Untitled.saveAs(document) } else { Task { await document.saveNow() } }
    }

    static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { openFile($0) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Self.openFile($0) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        Self.mark("will finish launching")
        #endif
        NSApp.appearance = NSAppearance(named: .darkAqua)   // dark only, always (A17)
        DockIcon.apply()   // hidden from the start if Settings says so (AP6), before a window shows
        #if DEBUG
        ScenarioFocus.start()   // a scenario's Nib doesn't take the Mac's focus
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Documents.watchClosing()
        _ = Updates.shared   // the daily update check (DS2), in released copies only
        // The trial or license (DS4): its clock starts at the first launch with licensing on.
        LicenseManager.shared.refresh()
        Task { await LicenseManager.shared.revalidateIfDue() }
        // Services › Append to Nib Scratch and Clean Text (SC8, PT7). Not a test run's Nib: it
        // would answer the user's.
        if !NibPaths.isScenario {
            NSApp.servicesProvider = ServiceProvider.shared
            NSUpdateDynamicServices()
        }
        let document = Self.document
        // First run (AP5): with no scratch file yet, none is made until the welcome window says so.
        let firstRun = FirstRun.needed
        let waitForChoice = firstRun && !FileManager.default.fileExists(atPath: document.url.path)
        if waitForChoice { document.awaitFirstRun() }
        let launched = Date()
        #if DEBUG
        if let started = TestHarness.processStart() { Self.launchPhases.append(("to launched", launched.timeIntervalSince(started))) }
        #endif
        Task {
            #if DEBUG
            Self.mark("the launch task starting")
            #endif
            await Document.settlePausedFiles(except: document.url)
            ClosedItems.shared.sweep()
            // The tabs open at the last quit come with the scratch file, not after its open: that
            // goes on past its text, through its hold and iCloud's questions about it, and they
            // came 1-2 s after it (the user, 2026-10-07).
            let scratch = Task {
                if !waitForChoice { await document.open() }
                #if DEBUG
                Self.launchPhases.append(("opening and holding the scratch file", Date().timeIntervalSince(launched)))
                Self.scratchOpenedAt = Date()
                #endif
            }
            await OpenTabs.restore()   // the tabs open at the last quit, in their order
            Untitled.restore()   // hot exit (ED3): any untitled buffers from before not among them (after a crash, all)
            await scratch.value
            // HTML isn't a kind Nib takes any more: given back once where it had it (2026-10-07,
            // the user's call; DefaultApps). Not the test harness's Nib, whose is a stand-in.
            if !NibPaths.isScenario, let said = await DefaultApps.shared.giveBackHTML() { document.show(said, for: 15) }
            #if DEBUG
            TestHarness.runIfRequested(document)
            #endif
        }
        // Show Scratch (SC2, ⌥Space), Clean Clipboard (PT4, ⌃⌥⌘V) and Append Clipboard to
        // Scratch (SC6, none), from any app, as Settings › General has them. Here, not queued
        // after the open: there its 20-30 ms landed as iCloud answered and held the text back
        // (§6.5, measured 2026-09-30). Not in the test harness's Nib: the keys are the Nib in
        // daily use's (the `firstrun` scenario registers its own).
        if !NibPaths.isScenario { GlobalShortcuts.shared.registerAll() }
        // Open at login (AP2): when it's on but another copy of Rune registered it, this copy's now.
        if !NibPaths.isScenario { _ = LoginItem.shared }
        observeSystem()
        MenuBarController.shared.start()   // the menu bar extra (§5.7), AppKit's own status item
        Notifier.shared.start()   // SY15: conflicts and files Nib can't save or sync, while it's in the background
        CLIBridge.start()   // the `nib` command-line tool (AP4)
        // ⌘K opens Go to File too (A6), as ⌘K "Go to…" does in Blit; a menu item takes only one key.
        // ⌘1…⌘9 pick a tab, as in Sublime (§5.12), but for ⌘1-⌘3 with the caret in a conflict block.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let key = Self.tabKey(event), NSApp.keyWindow?.isSheet != true,
                  NSApp.keyWindow?.attachedSheet == nil,
                  !(NSApp.keyWindow?.firstResponder is ShortcutRecorder) else { return event }   // new keys being typed
            let handled = MainActor.assumeIsolated {
                switch key {
                case .goToFile: Self.showPalette(.files, in: nil); return true
                case .tab(let number): return Self.selectTab(number, in: NSApp.keyWindow)
                }
            }
            return handled ? nil : event
        }
        // After SwiftUI has put up the scratch window, so the welcome window is in front of it.
        if firstRun { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { FirstRun.shared.show() } }
        #if DEBUG
        Self.mark("did finish launching done")
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Documents.all.forEach { $0.becameActive() }
        LicenseManager.shared.refresh()   // DS4: a Mac's day can pass with Rune behind
        Task { await LicenseManager.shared.revalidateIfDue() }   // weekly; nothing to do otherwise
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

    /// The Dock's menu: while the ✕ is on the icon (AP8), a line for each file with conflict
    /// blocks, opening it. The ✕ is drawn on the tile, which has no words for VoiceOver (macOS
    /// says a Dock item's name and its system badge only): here they are (the QA review's F82).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let conflicted = Documents.all.filter { !$0.blocks.isEmpty }
        guard !conflicted.isEmpty else { return nil }
        let menu = NSMenu()
        for document in conflicted {
            let places = document.blocks.count
            let item = NSMenuItem(title: "Conflict in \(Alerts.quoted(document.url.lastPathComponent)), \(places) place\(places == 1 ? "" : "s")",
                                  action: #selector(openFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = document.url
            menu.addItem(item)
        }
        return menu
    }

    @objc func openFromDock(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSApp.activate()
        Self.openFile(url)
    }

    /// Quitting: save, upload, hand every file back to iCloud; a watchdog makes sure it ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminating = true
        OpenTabs.record()   // before anything closes: the tabs, for the next launch
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
            NSLog("Rune: couldn't set up the relaunch: \(error)")
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
        // iCloud on again, or signed in (§4.9, 11): files that went with it are looked for.
        NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in for document in Documents.all { document.cloudIdentityChanged() } }
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
    @AppStorage("editorLineNumbers", store: NibDefaults.store) private var lineNumbers = true
    @AppStorage("editorInvisibles", store: NibDefaults.store) private var invisibles = false
    @AppStorage("editorMinimap", store: NibDefaults.store) private var minimap = true
    @Environment(\.openWindow) private var openWindow

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }
    private func find(_ command: (FindSession) -> Void, else action: Selector) {
        guard !merging, NSApp.keyWindow?.isSheet != true else { NSSound.beep(); return }
        if let document {
            command(document.editor.find)
        } else if NSApp.keyWindow?.identifier?.rawValue.contains("sync-log") == true {
            NotificationCenter.default.post(name: SyncLogView.find, object: nil)   // its search field
        } else {
            send(action)
        }
    }

    /// One of the find bar's options, for its menu item.
    private func findOption(_ path: ReferenceWritableKeyPath<FindSession, Bool>) -> Binding<Bool> {
        Binding(get: { document.map { $0.editor.find[keyPath: path] } ?? false },
                set: { value in document.map { $0.editor.find[keyPath: path] = value } })
    }

    /// The merge view is up: Find, Replace, Go to Line and the sync HUD would act on the window
    /// behind it, under the sheet (the QA review's F31, 2026-10-07).
    private var merging: Bool { document?.merge != nil }

    /// A window with no editor in front (Settings, History, the Sync Log), or an editor that can't
    /// be changed: the text commands did nothing, silently, enabled all the same (the QA review's
    /// F46). With no window in front (Nib behind another app) they're sent on as before.
    private var noEditor: Bool { document == nil && NSApp.keyWindow != nil }
    private var cantEdit: Bool { noEditor || document?.locked != nil }
    /// No changes since the last commit to go to or revert (ED12): outside a repository, or none.
    private var noChanges: Bool { merging || document?.git.changes.hunks.isEmpty != false }

    var body: some Commands {
        // Blit's About, not the standard panel (§5.10).
        CommandGroup(replacing: .appInfo) {
            Button("About Rune") { openWindow(id: "about") }
            // Sparkle (DS2): released copies only; a Debug build or a test run's has it off.
            Button("Check for Updates…") { Updates.shared.checkNow() }
                .disabled(!Updates.shared.isAvailable || !Updates.shared.canCheck)
            // DS4, from Blit's app menu: only while licensing is on. Once a key is in, nothing to
            // buy or enter: License… opens Settings › License (whose it is, Deactivate This Mac).
            if LicenseManager.shared.isEnforced { LicenseMenuItems() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New") { AppDelegate.newUntitled() }
                .keyboardShortcut("n")
            // A browser's and Terminal's key for a tab: the same, a tab in the window in front.
            Button("New Tab") { AppDelegate.newUntitled() }
                .keyboardShortcut("t")
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
            // Close is in this group too: replacing the group took it, and ⌘W with it (the user,
            // 2026-10-02). The window in front: a file's tab (saved, uploaded, handed back), the
            // scratch window (⌥Space or the Dock brings it back), Settings, History, the Sync Log.
            // "Close Tab" in a window of tabs, as Apple's apps say it, and Close Window for all of
            // them (the QA review's F78).
            CloseMenuItems()
            Divider()
            // Everything saves by itself; ⌘S saves and uploads now. An untitled buffer asks
            // where to put it (W3).
            Button(document?.untitled == true ? "Save…" : "Save") { document.map(AppDelegate.save) }
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
            Divider()
            // The strip's and the banners' commands, in a menu too, so in the palette (KB1, KB3;
            // the QA review's F44: Show in Finder, the file's Sync Log, Restore, Empty Trash).
            Button("Show in Finder") { document.map { NSWorkspace.shared.activateFileViewerSelecting([$0.url]) } }
                .disabled(document == nil || document?.untitled == true || document?.deleted == true)
            Button("Show Sync Log for This File") { document.map { SyncLogModel.shared.show(file: $0.url, openWindow: openWindow) } }
                .disabled(document == nil || document?.untitled == true)
            Button("Restore") { Task { await document?.restoreDeleted() } }
                .disabled(document?.deleted != true || document?.iCloudOff == true)
            if document?.trashOffer != nil {
                Button("Empty Trash…") { Task { await document?.emptyTrashForSpace() } }
            }
        }
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { AppDelegate.showPalette(.commands, in: document) }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Menu("Syntax") { SyntaxMenuItems(document: document) }
                .disabled(document == nil)
            // A file's indentation and line endings (the QA review's F50), as on the strip.
            Menu("Indentation") { IndentationMenuItems(document: document) }
                .disabled(document == nil || document?.locked != nil || merging)
            Menu("Line Endings") { LineEndingMenuItems(document: document) }
                .disabled(document == nil || document?.locked != nil || merging)
            // Line numbers, invisibles (ED6) and the minimap (ED11), for every window; Settings › Editor too.
            Button(lineNumbers ? "Hide Line Numbers" : "Show Line Numbers") { lineNumbers.toggle() }
            Button(invisibles ? "Hide Invisibles" : "Show Invisibles") { invisibles.toggle() }
            Button(minimap ? "Hide Minimap" : "Show Minimap") { minimap.toggle() }
            Divider()
            // The sync HUD (§5.3) over the text of the window in front.
            Button(document?.syncDetailsShown == true ? "Hide Sync Details" : "Show Sync Details") { document?.toggleSyncDetails() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(document == nil || merging)
        }
        // Nib doesn't print; ⌘P and ⇧⌘P are Sublime's palette keys.
        CommandGroup(replacing: .printItem) {}
        // Edit's clipboard commands (PT1-PT4, SC5, SC6), sent to whatever has focus.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button("Copy") { send(#selector(NSText.copy(_:))) }.keyboardShortcut("c")
            Button("Copy Block") { send(#selector(NibTextView.copyBlock(_:))) }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(noEditor)
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
                    .keyboardShortcut("f").disabled(merging)
                Button("Find and Replace…") { find({ $0.open(replace: true) }, else: #selector(NibTextView.showFindAndReplace(_:))) }
                    .keyboardShortcut("f", modifiers: [.command, .option]).disabled(merging)
                Button("Find Next") { find({ $0.next() }, else: #selector(NibTextView.findNextMatch(_:))) }
                    .keyboardShortcut("g").disabled(merging)
                Button("Find Previous") { find({ $0.next(backwards: true) }, else: #selector(NibTextView.findPreviousMatch(_:))) }
                    .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(merging)
                Button("Use Selection for Find") { find({ $0.useSelection() }, else: #selector(NibTextView.useSelectionForFind(_:))) }
                    .keyboardShortcut("e").disabled(merging)
                // Only with the bar open: elsewhere ⌥Return is the text's own.
                Button("Find All") { document?.editor.find.findAll() }.keyboardShortcut(.return, modifiers: .option)
                    .disabled(document?.editor.find.shown != true || merging)
                Divider()
                // Only with the Replace row shown (⌥⌘F): from ⌘F's bar they'd replace with what
                // nobody can see (the QA review's F1).
                Button("Replace") { document?.editor.find.replaceCurrent() }.keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(document?.editor.find.shown != true || document?.editor.find.replacing != true || merging)
                Button("Replace All") { document?.editor.find.replaceAll() }.keyboardShortcut(.return, modifiers: [.control, .option])
                    .disabled(document?.editor.find.shown != true || document?.editor.find.replacing != true || merging)
                Divider()
                // The bar's options, while it's shown, Sublime's keys where they're free (⌥⌘R is
                // Resolve's): they were only the bar's buttons (the QA review's F51).
                Group {
                    Toggle("Regular Expression", isOn: findOption(\.options.regex))
                    Toggle("Match Case", isOn: findOption(\.options.matchCase)).keyboardShortcut("c", modifiers: [.command, .option])
                    Toggle("Whole Word", isOn: findOption(\.options.wholeWord)).keyboardShortcut("w", modifiers: [.command, .option])
                    Toggle("In Selection", isOn: findOption(\.inSelection))
                }
                .disabled(document?.editor.find.shown != true || merging)
            }
        }
        // Sublime's line commands on Sublime's keys (ED6, KB4, §5.12).
        CommandMenu("Text") {
            Button("Indent") { send(#selector(NibTextView.indentLines(_:))) }.keyboardShortcut("]").disabled(cantEdit)
            Button("Outdent") { send(#selector(NibTextView.outdentLines(_:))) }.keyboardShortcut("[").disabled(cantEdit)
            Button("Toggle Comment") { send(#selector(NibTextView.toggleComment(_:))) }.keyboardShortcut("/").disabled(cantEdit)
            Divider()
            Button("Duplicate Line") { send(#selector(NibTextView.duplicateLine(_:))) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(cantEdit)
            Button("Move Line Up") { send(#selector(NibTextView.moveLineUp(_:))) }.keyboardShortcut(.upArrow, modifiers: [.command, .control]).disabled(cantEdit)
            Button("Move Line Down") { send(#selector(NibTextView.moveLineDown(_:))) }.keyboardShortcut(.downArrow, modifiers: [.command, .control]).disabled(cantEdit)
            Button("Select Line") { send(#selector(NibTextView.selectWholeLine(_:))) }.keyboardShortcut("l").disabled(noEditor)
            Button("Join Lines") { send(#selector(NibTextView.joinLines(_:))) }.keyboardShortcut("j").disabled(cantEdit)
            Divider()
            Button("Go to Line…") { if !merging { document?.goingToLine = true } }.keyboardShortcut("g", modifiers: .control).disabled(document == nil || merging)
            // Sublime's Goto Symbol (SC7): a Markdown file's headings.
            Button("Go to Heading…") { AppDelegate.showPalette(.headings, in: document) }.keyboardShortcut("r").disabled(document == nil || merging)
            // Changes since the last commit (ED12), on Sublime's keys; a click on a mark shows one.
            Divider()
            Button("Next Change") { document?.git.go(forward: true) }.keyboardShortcut(".", modifiers: .control).disabled(noChanges)
            Button("Previous Change") { document?.git.go(forward: false) }.keyboardShortcut(",", modifiers: .control).disabled(noChanges)
            Button("Revert Change") { document?.git.revertAtCaret() }.disabled(noChanges || cantEdit)
        }
        // Multiple carets (ED8), on Sublime's keys; Escape is one caret again.
        CommandMenu("Selection") {
            Group {
                Button("Add Next Occurrence") { send(#selector(NibTextView.selectNextOccurrence(_:))) }.keyboardShortcut("d")
                Button("Skip to Next Occurrence") { send(#selector(NibTextView.skipToNextOccurrence(_:))) }   // ⌘K ⌘D: open question 10
                Button("Select All Occurrences") { send(#selector(NibTextView.selectAllOccurrences(_:))) }.keyboardShortcut("g", modifiers: [.command, .control])
                Button("Split into Lines") { send(#selector(NibTextView.splitSelectionIntoLines(_:))) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Divider()
                Button("Add Caret Above") { send(#selector(NibTextView.addCaretAbove(_:))) }.keyboardShortcut(.upArrow, modifiers: [.control, .shift])
                Button("Add Caret Below") { send(#selector(NibTextView.addCaretBelow(_:))) }.keyboardShortcut(.downArrow, modifiers: [.control, .shift])
                Divider()
                Button("Undo Selection") { send(#selector(NibTextView.undoSelection(_:))) }.keyboardShortcut("u")
                Button("Redo Selection") { send(#selector(NibTextView.redoSelection(_:))) }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("One Caret") { send(#selector(NibTextView.singleCaret(_:))) }   // Escape too; not in its title (F76)
            }
            .disabled(noEditor)   // F46
        }
        CommandMenu("Conflicts") { ConflictMenuItems(document: document) }
        // The first run again (AP5), in place of the Help Book Nib doesn't have.
        CommandGroup(replacing: .help) {
            Button("Welcome to Rune") { FirstRun.shared.show() }
        }
        CommandGroup(before: .windowArrangement) {
            // Show Scratch (SC2, P0) with its global keys, as Settings › General has them, so it's
            // in a menu and the palette (the QA review's F47).
            Button("Show Scratch") { AppDelegate.showScratch() }.globalShortcut(GlobalShortcuts.shared.shortcut(.showScratch))
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
/// Rune › Buy Rune… and Enter License…, or License… once a key is in (DS4). A view of its own, as
/// `CloseMenuItems` is: in the commands' body, a change of license left the menu as it was.
struct LicenseMenuItems: View {
    var body: some View {
        if LicenseManager.shared.isLicensed {
            Button("License…") { LicenseManager.shared.openLicenseSettings() }
        } else {
            Button("Buy Rune…") { LicenseManager.shared.openBuyPage() }
            Button("Enter License…") { LicenseManager.shared.openLicenseSettings() }
        }
    }
}

/// File › Close, or Close Tab in a window of tabs, and Close Window (F78). A view of its own, as
/// the Conflicts menu's items are: SwiftUI follows what a view's body reads.
struct CloseMenuItems: View {
    var body: some View {
        let tabbed = KeyWindowTabs.shared.tabbed
        Button(tabbed ? "Close Tab" : "Close") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
            .keyboardShortcut("w")
        Button("Close Window") {
            for window in NSApp.keyWindow?.tabbedWindows ?? [] { window.performClose(nil) }
        }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(!tabbed)
    }
}

struct OpenRecentMenu: View {
    var body: some View {
        Menu("Open Recent") {
            ForEach(RecentFiles.shared.urls, id: \.self) { url in
                Button(url.lastPathComponent) { AppDelegate.openListed(url) }
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
        urls = (NibDefaults.store.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        // (Not from the test harness's Nib: the system's list is the bundle's, the user's Nib's too.)
        if !NibPaths.isScenario { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        urls.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        urls.insert(url, at: 0)
        if urls.count > 10 { urls.removeLast(urls.count - 10) }
        NibDefaults.store.set(urls.map(\.path), forKey: key)
    }

    /// Moved or renamed (ED4): its old path isn't a file any more.
    func remove(_ url: URL) {
        urls.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        NibDefaults.store.set(urls.map(\.path), forKey: key)
    }

    func clear() {
        if !NibPaths.isScenario { NSDocumentController.shared.clearRecentDocuments(nil) }
        urls = []
        NibDefaults.store.removeObject(forKey: key)
    }
}

/// Whether the window in front is one of several tabs: File › Close Tab, and Close Window on
/// (the QA review's F78). Observed, so the menus follow it: SwiftUI makes the commands again
/// only when something they read changes, and the key window isn't such a thing (the title
/// stayed "Close" in a window of tabs, and ⇧⌘W off: the suite, 2026-10-07).
@MainActor
@Observable
final class KeyWindowTabs {
    static let shared = KeyWindowTabs()
    private(set) var tabbed = false

    private init() {
        // A window coming in front or going, and tabs joined or parted: each window's update,
        // after every event, is a look at one count.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        let now = (NSApp.keyWindow?.tabbedWindows?.count ?? 0) > 1
        if now != tabbed { tabbed = now }
    }
}

/// The Conflicts menu (PRD §5.4, §5.12): with the caret in a block, ⌘1 uses the first
/// version, ⌘2 the second, ⌘3 keeps both; ⌥⌘↓ and ⌥⌘↑ go between blocks; Merge View… (⌥⌘R)
/// opens the merge view. In the merge view, they act on its result.
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
        // Always the merge view, as its ellipsis says: "Resolve…" went to the next block with three
        // or fewer, asking nothing (the QA review's F52). The banner's button still does that.
        Button("Merge View…") { document?.openMerge() }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(document?.blocks.isEmpty != false || document?.merge != nil)
    }
}
