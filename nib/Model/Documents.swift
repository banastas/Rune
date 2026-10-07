// Every open file's Document (PRD ED2): one per file, so opening a file again brings its
// window forward rather than a second buffer. The scratch file is one of them and stays
// open with or without its window (SC1); a file's document lives as long as its window.

import AppKit
import NibSync

@MainActor
enum Documents {
    static let scratch = Document(url: ScratchLocation.url)
    private static var files: [String: Document] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// The scratch document and every file's.
    static var all: [Document] { [scratch] + files.values.sorted { $0.url.path < $1.url.path } }

    /// The file's document if it's open.
    static func existing(for url: URL) -> Document? {
        key(url) == key(scratch.url) ? scratch : files[key(url)]
    }

    /// The file's document, opened if it isn't yet.
    static func document(for url: URL) -> Document {
        if let open = existing(for: url) { return open }
        let document = Document(url: url)
        files[key(url)] = document
        Task { await document.open() }
        MenuBarController.shared.refresh()   // the menu bar item watches this one too, from now on
        return document
    }

    /// A document let go without closing it: its file moved away, and it opens again there.
    static func forget(_ document: Document) {
        guard document !== scratch, files[key(document.url)] === document else { return }
        files[key(document.url)] = nil
        MenuBarController.shared.refresh()
        DockBadge.shared.update()
    }

    /// Any window closing lets go of the file whose text is in it: one watch for every window,
    /// by the text it holds. A watch a window, set where its view first landed, missed a tab
    /// made from the scratch window (it landed in one window and closed in another), and its
    /// buffer stayed open with no window and its untitled file stayed behind (2026-10-02).
    static func watchClosing() {
        // As it's posted (no queue): queued for later, the window's view had gone by then.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: nil) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                for document in files.values where document.editor.textView.window === window {
                    Task { await close(document) }
                }
            }
        }
    }

    /// Its window has closed: save, upload, hand the file back to iCloud, and forget it. An
    /// untitled buffer goes to History (ED3); either goes on File › Reopen Closed File. Not
    /// when quitting: then untitled buffers stay, to come back at the next launch.
    /// `keepEmpty`: Rename and Move To close a file to move it, a new one `nib` made included.
    static func close(_ document: Document, keepEmpty: Bool = false) async {
        guard document !== scratch, files[key(document.url)] === document else { return }
        files[key(document.url)] = nil
        MenuBarController.shared.refresh()
        DockBadge.shared.update()   // its blocks go with it (AP8)
        await document.close()
        CLIBridge.closed(document.url)   // `nib -w` (AP4): its text is in the file now
        guard !AppDelegate.terminating else { return }
        // Made empty as it opened, and closed empty: gone again, with what Nib kept for it (F3).
        if !keepEmpty, await document.removeIfLeftEmpty() {
            ClosedItems.removeKept(for: document.url.path)
            RecentFiles.shared.remove(document.url)
            return
        }
        if document.untitled {
            await Untitled.discard(document)
        } else if document.locked == nil, !document.deleted {   // a deleted file's text is on the list already
            ClosedItems.shared.add(.init(path: document.url.path, name: document.url.lastPathComponent, untitled: false, sha256: nil, time: Date()))
        }
    }
}
