// Nib: a small, fast macOS text editor that never loses a keystroke between Macs.
// The scratch window, file windows as native tabs (ED2), and the sync pipeline of §4;
// on test files only until M1 has passed (the safety rule, §8).

import AppKit
import Carbon.HIToolbox
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
                // The tab bar's + (a window with no file): the Open panel instead, until
                // untitled buffers (ED3) exist.
                Color.clear.background(WindowConfigurator { window in
                    DispatchQueue.main.async { window.close(); AppDelegate.showOpenPanel() }
                })
            }
        }
        .defaultSize(width: 760, height: 600)
        WindowGroup("History", id: "history", for: URL.self) { $url in
            HistoryWindow(url: url)
        }
        .defaultSize(width: 820, height: 520)
        .commands { NibCommands() }
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

    /// ⌘O, Open Recent, Finder's Open With, the Dock (ED2): the file's window, a tab beside the others.
    static func openFile(_ url: URL) {
        RecentFiles.shared.add(url)
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let document = Self.document
        Task {
            await Document.settlePausedFiles(except: document.url)
            await document.open()
            #if DEBUG
            TestHarness.runIfRequested(document)
            #endif
        }
        // Show Scratch (SC2): ⌥Space, toggling. ⌃Space and ⌃⌥Space are macOS's input-source keys.
        if !HotKey.register(id: 1, keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), action: { Self.toggleScratch() }) {
            NSLog("Nib: ⌥Space is taken by another app")
        }
        observeSystem()
    }

    func applicationDidBecomeActive(_ notification: Notification) { Documents.all.forEach { $0.becameActive() } }
    func applicationDidResignActive(_ notification: Notification) { Documents.all.forEach { $0.resignedActive() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showScratch() }
        return true
    }

    /// Quitting: save, upload, hand every file back to iCloud; a watchdog makes sure it ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for document in Documents.all { group.addTask { await document.close() } }
            }
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { AppDelegate.showOpenPanel() }
                .keyboardShortcut("o")
            OpenRecentMenu()
        }
        CommandGroup(replacing: .saveItem) {
            // Everything saves by itself; ⌘S saves and uploads now.
            Button("Save") { if let document { Task { await document.flush(reason: "⌘S") } } }
                .keyboardShortcut("s")
                .disabled(document == nil)
            if let document { RevertToMenu(document: document) } else { Menu("Revert To") {}.disabled(true) }
        }
        CommandMenu("Conflicts") { ConflictMenuItems(document: document) }
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
    private(set) var urls = NSDocumentController.shared.recentDocumentURLs

    func add(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        urls = NSDocumentController.shared.recentDocumentURLs
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        urls = []
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
