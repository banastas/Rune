// nib: a small, fast macOS text editor that never loses a keystroke between Macs.
// M1, the weekend MVP (PRD §8): the scratch window, plain paste, and the sync
// pipeline of §4, on test files in iCloud Drive/nib-spike/ until M1 has passed.

import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct NibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        HUDFont.registerBundled()
    }

    var body: some Scene {
        Window("Scratch", id: "scratch") {
            ScratchView(document: AppDelegate.document)
        }
        .defaultSize(width: 720, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}   // one scratch file in M1
            CommandGroup(replacing: .saveItem) {
                // Everything saves by itself; ⌘S saves and uploads now.
                Button("Save") { Task { await AppDelegate.document.flush(reason: "⌘S") } }
                    .keyboardShortcut("s")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let document = Document(url: ScratchLocation.url)
    /// Set by the window when it first appears; reopens it after ⌘W.
    static var openScratchWindow: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)   // dark only, always (A17)
        NSWindow.allowsAutomaticWindowTabbing = false
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
            NSLog("nib: ⌥Space is taken by another app")
        }
        observeSystem()
    }

    func applicationDidBecomeActive(_ notification: Notification) { Self.document.becameActive() }
    func applicationDidResignActive(_ notification: Notification) { Self.document.resignedActive() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showScratch() }
        return true
    }

    /// Quitting: save, upload, hand the file back to iCloud; a watchdog makes sure it ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await Self.document.close()
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
                Task { @MainActor in await Self.document.flush(reason: reason) }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Self.document.fetchLatest(reason: "wake") }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil, queue: .main) { _ in
            Task { @MainActor in await Self.document.flush(reason: "screen locked") }
        }
    }
}
