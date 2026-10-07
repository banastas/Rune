// The files open when Nib quit, open again at the next launch (the user's call, 2026-10-07):
// untitled buffers came back (hot exit, ED3), files didn't, and only the scratch window was
// there. Recorded as a quit begins, before the documents close: every Nib window's tabs in
// order, the front window's first, and the tab in front. Reopened once the scratch file is,
// each tab after the one before, the one in front in front again; a file gone since isn't made
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

    /// At launch, once the scratch file is open: the tabs from the last quit, once.
    static func restore() async {
        let store = NibDefaults.store
        let paths = store.stringArray(forKey: listKey) ?? [], front = store.string(forKey: frontKey)
        store.removeObject(forKey: listKey)
        store.removeObject(forKey: frontKey)
        guard enabled, !paths.isEmpty else { return }
        var previous = AppDelegate.scratchWindow
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if Untitled.contains(url) {
                guard FileManager.default.fileExists(atPath: path), Untitled.worthRestoring(url) else { continue }
            } else {
                guard FileManager.default.fileExists(atPath: path) else { continue }   // gone since: not made again
            }
            FileWindow.tabHost = previous   // each tab after the one before, in the order they were
            guard AppDelegate.openFile(url, reopening: true) else { continue }
            for _ in 0..<50 {   // its window, in the tabs (up to 5 s)
                if let window = Documents.existing(for: url)?.editor.textView.window, window.isVisible,
                   previous == nil || previous?.tabGroup?.windows.contains(window) == true {
                    // macOS tabs a new window in beside the selected tab (the scratch window's, at
                    // first), so they came back last first: put it after the one before, and select it.
                    if let previous, let group = previous.tabGroup, let at = group.windows.firstIndex(of: previous),
                       group.windows.firstIndex(of: window) != at + 1 {
                        group.removeWindow(window)
                        group.insertWindow(window, at: min(at + 1, group.windows.count))
                    }
                    window.makeKeyAndOrderFront(nil)
                    previous = window
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        FileWindow.tabHost = nil
        if let front, let window = Documents.existing(for: URL(fileURLWithPath: front))?.editor.textView.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
    }
}
