// The files open when Nib quit, open again at the next launch (the user's call, 2026-10-07):
// untitled buffers came back (hot exit, ED3), files didn't, and only the scratch window was
// there. Recorded as a quit begins, before the documents close: every Nib window's tabs in
// order, the front window's first, and the tab in front. Reopened with the scratch file, after
// its tab and in their order, the one in front in front again; a file gone since isn't made
// again, and one over 100 MB isn't asked about again (ED9: it was open). Settings › Files turns
// it off. A test run's Nib does it only when asked (-NibReopenFiles YES): leftover tabs from one
// scenario in the next were trouble before (`fileops`' 16 tabs, 2026-10-06).

import AppKit
import NibSync

@MainActor
enum OpenTabs {
    static let listKey = "openTabsAtQuit"
    static let frontKey = "frontTabAtQuit"
    static let settingKey = "reopenFilesAtLaunch"

    static var enabled: Bool {
        if NibPaths.isScenario { return NibDefaults.store.bool(forKey: "NibReopenFiles") }
        return NibDefaults.store.object(forKey: settingKey) as? Bool ?? true
    }

    /// At a quit's start: the open files and untitled buffers in tab order (not the scratch file,
    /// which always opens), and the one in front.
    static func record() {
        let store = NibDefaults.store
        guard enabled else {
            store.removeObject(forKey: listKey)
            store.removeObject(forKey: frontKey)
            return
        }
        func document(_ window: NSWindow) -> Document? { Documents.all.first { $0.editor.textView.window === window } }
        let windows = NSApp.orderedWindows.filter { $0.tabbingIdentifier == "nib.file" && $0.isVisible }   // front to back
        var seen = Set<ObjectIdentifier>(), paths: [String] = []
        for window in windows {
            for tab in window.tabGroup?.windows ?? [window] where seen.insert(ObjectIdentifier(tab)).inserted {
                guard let document = document(tab), document !== Documents.scratch, !document.deleted else { continue }
                paths.append(document.url.path)
            }
        }
        store.set(paths, forKey: listKey)
        let front = windows.first.map { $0.tabGroup?.selectedWindow ?? $0 }.flatMap(document)
        store.set(front?.url.path, forKey: frontKey)
    }

    /// At launch, beside the scratch file's open: the tabs from the last quit, once. Every window
    /// asked for at once, then put in order: one at a time, each waited for in the tabs, was
    /// 0.2-0.4 s a file, after the scratch file's hold (the user, 2026-10-07: "a pause").
    static func restore() async {
        let store = NibDefaults.store
        let paths = store.stringArray(forKey: listKey) ?? [], front = store.string(forKey: frontKey)
        store.removeObject(forKey: listKey)
        store.removeObject(forKey: frontKey)
        guard enabled, !paths.isEmpty else { return }
        // The scratch window first (up to 3 s): the tabs go after it.
        for _ in 0..<60 where AppDelegate.scratchWindow?.isVisible != true { try? await Task.sleep(for: .milliseconds(50)) }
        let host = AppDelegate.scratchWindow
        var urls: [URL] = []
        FileWindow.tabHost = host
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }   // gone since: not made again
            if Untitled.contains(url), !Untitled.worthRestoring(url) { continue }
            if AppDelegate.openFile(url, reopening: true) { urls.append(url) }
        }
        func window(_ url: URL) -> NSWindow? {
            Documents.existing(for: url)?.editor.textView.window.flatMap { $0.isVisible ? $0 : nil }
        }
        // Their windows in the tabs, each put in its place (up to 5 s): a place made after the one
        // in front was chosen took it to the front.
        for _ in 0..<100 {
            if urls.allSatisfy({ url in
                window(url).map { (host?.tabGroup?.windows.contains($0) ?? true) && !FileWindow.joining.contains(ObjectIdentifier($0)) } ?? false
            }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        FileWindow.tabHost = nil
        // In the order they were, after the scratch file's tab. (Each goes after the files asked
        // for before it, `FileWindow.joinTabs`, so this is for one that came late.)
        if let host, let group = host.tabGroup {
            var previous = host
            for url in urls {
                guard let window = window(url), group.windows.contains(window) else { continue }
                if let at = group.windows.firstIndex(of: previous), group.windows.firstIndex(of: window) != at + 1 {
                    group.removeWindow(window)
                    group.insertWindow(window, at: min((group.windows.firstIndex(of: previous) ?? at) + 1, group.windows.count))
                }
                previous = window
            }
        }
        if let front, let window = Documents.existing(for: URL(fileURLWithPath: front))?.editor.textView.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        #if DEBUG
        restoredAt = Date()
        #endif
    }

    #if DEBUG
    /// When the tabs were back, for `reopen-return`.
    static var restoredAt: Date?
    #endif
}
