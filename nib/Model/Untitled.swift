// Untitled buffers (PRD ED3): File › New, ⌘N. Each is a file of Nib's own, on this Mac only
// (open question 12: local), at ~/Library/Application Support/nib/Untitled/<id>/Untitled 2,
// so the journal, saving, History and crash recovery work as for any file, and they come
// back after a quit or a crash (Sublime's hot exit). Nothing about them syncs, and they
// stay out of the Sync Log. Closing a non-empty one keeps its text in History for 30 days,
// and File › Reopen Closed File (⇧⌘T) brings it back; an empty one just goes (V8: no "Save?"),
// its History with it unless that keeps text it once had. File › Save… makes one a file, and
// Rename… another buffer; its History goes on there (guarantee 2).

import AppKit
import NibSync
import NibText

@MainActor
enum Untitled {
    nonisolated static var folder: URL { NibPaths.support.appendingPathComponent("Untitled", isDirectory: true) }

    nonisolated static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// The untitled buffers on this Mac, oldest first.
    static func all() -> [URL] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        func created(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return ids.sorted { created($0) < created($1) }
            .compactMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.first }
    }

    /// A new untitled buffer's file, named "Untitled", "Untitled 2"… (the lowest number free), or
    /// as asked ("notes copy.md", then "notes copy 2.md").
    static func create(text: String = "", name wanted: String = "Untitled") -> URL? {
        let taken = Set(all().map(\.lastPathComponent))
        let base = (wanted as NSString).deletingPathExtension, ext = (wanted as NSString).pathExtension
        var name = wanted, n = 1
        while taken.contains(name) { n += 1; name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)" }
        let file = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        } catch {
            return nil
        }
        return file
    }

    /// At launch: every untitled buffer from before comes back; empty ones are let go.
    static func restore() {
        for url in all() {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let journaled = Journal(directory: NibPaths.support.appendingPathComponent("Journal")).read(path: url.path) != nil
            if size == 0, !journaled {
                letGoEmpty(url, data: Data(), history: History(root: NibPaths.support.appendingPathComponent("History"), path: url.path))
                remove(url)
                continue
            }
            AppDelegate.openFile(url)
        }
    }

    /// Its window closed (not a quit): its text stays in History and on the Reopen Closed
    /// list for 30 days; an empty buffer just goes (`letGoEmpty`). One whose text went on
    /// elsewhere (Save…, Rename…) takes its History and caret there; one let go keeps nothing.
    static func discard(_ document: Document) async {
        let url = document.url
        defer { remove(url) }
        await document.historyWritten()   // its last versions in, under this path, before they go anywhere
        if let new = handedOver.removeValue(forKey: url.path) {
            FileCommands.carrySettings(from: url, to: new, syntax: false)
            return
        }
        if lettingGo.remove(url.path) != nil {
            ClosedItems.removeKept(for: url.path)
            return
        }
        let text = document.editor.textView.string
        let data = TextFile.encode(text, as: document.format)
        guard !text.isEmpty else { letGoEmpty(url, data: data, history: document.history); return }
        try? document.history.record(data, parent: nil, source: "closed")
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: Digest.sha256(data), time: Date()))
    }

    /// An empty buffer going, closed or empty at a launch: nothing kept, History and all (every
    /// ⌘N or ⌘T closed untouched had left a folder there for good, §8). Unless its History keeps
    /// text it once had (typed in, then emptied): then it's on Reopen Closed File as a closed
    /// buffer is, back empty with that text in its History (guarantee 2; the user's call).
    private static func letGoEmpty(_ url: URL, data: Data, history: History) {
        let sha = Digest.sha256(data)
        guard history.entries().contains(where: { $0.sha256 != sha }) else {
            ClosedItems.removeKept(for: url.path)
            return
        }
        try? history.record(data, parent: nil, source: "closed")
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: sha, time: Date()))
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Buffers whose text went on elsewhere (Save…, Rename…), and where.
    private static var handedOver: [String: URL] = [:]

    /// Buffers closed with nothing kept (`letGo`).
    private static var lettingGo: Set<String> = []

    /// Closing it keeps nothing, History and all: a buffer whose text nobody needs back (the
    /// scenarios'; each `large` run had left 92 MB in their History, §8).
    static func letGo(_ url: URL) {
        lettingGo.insert(url.path)
    }

    /// Its text goes on at `new` (Save…, Rename…): the buffer closes keeping nothing here, its
    /// History and caret go to `new` as a file's do with Rename… and Move To… (guarantee 2; left
    /// here, nothing opened or thinned them again, §8), and `new` opens in its place.
    static func handOver(_ document: Document, to new: URL) async {
        // Its window closing already: it goes on Reopen Closed File as any closed buffer does.
        guard Documents.existing(for: document.url) === document else { AppDelegate.openFile(new); return }
        let window = document.editor.textView.window
        document.editor.textView.isEditable = false   // nothing typed now that `new` wouldn't have
        handedOver[document.url.path] = new
        await Documents.close(document)   // its last version into its History, which `discard` carries
        guard !AppDelegate.terminating else { return }   // quitting: it comes back at the next launch, as it was
        AppDelegate.openFile(new)
        window?.close()
    }

    // MARK: Save… (W3: the first save of an untitled document asks where)

    static func saveAs(_ document: Document) {
        let panel = NSSavePanel()
        panel.title = "Save “\(document.url.lastPathComponent)”"
        let name = document.url.lastPathComponent
        // "notes copy.md" as it is; a new buffer named for its syntax, Markdown unless another was picked.
        let suffix = document.pickedSyntax == .language(.markdown) ? ".md" : ".txt"
        panel.nameFieldStringValue = (name as NSString).pathExtension.isEmpty ? name + suffix : name
        panel.directoryURL = ScratchLocation.url.deletingLastPathComponent()   // the test folder, until M1 passes (§8)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task { await save(document, to: target) }
    }

    /// Writes the buffer to `target` and opens that file in its place, the buffer's History and
    /// caret with it.
    @discardableResult
    static func save(_ document: Document, to target: URL) async -> Bool {
        if let reason = ScratchLocation.refusal(for: target) {
            document.show(reason, for: 12)
            return false
        }
        if Documents.existing(for: target) != nil {
            document.show("“\(target.lastPathComponent.uppercased())” IS OPEN IN NIB · CLOSE IT FIRST, OR PICK ANOTHER NAME", for: 12)
            return false
        }
        let data = TextFile.encode(document.editor.textView.string, as: document.format)
        do {
            // Over a file that's there (the panel asked first) or a new one, in place (§4.3).
            let base = FileManager.default.fileExists(atPath: target.path) ? try FileAccess.read(target).fingerprint : nil
            guard case .written = try FileAccess.write(data, to: target, base: base) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            document.show("COULDN'T SAVE “\(target.lastPathComponent.uppercased())” · \(error.localizedDescription.uppercased())", for: 12)
            return false
        }
        await handOver(document, to: target)
        return true
    }
}

/// File › Reopen Closed File (⇧⌘T, PRD §5.12): files and untitled buffers closed lately,
/// newest first. An untitled one comes back from History, for 30 days.
@MainActor
@Observable
final class ClosedItems {
    static let shared = ClosedItems()

    struct Item: Codable, Hashable {
        var path: String
        var name: String
        var untitled: Bool
        /// An untitled buffer's text, in History.
        var sha256: String?
        var time: Date
    }

    private(set) var items: [Item] = []
    private let key = "recentlyClosed"

    private init() {
        if let data = NibDefaults.store.data(forKey: key), let saved = try? JSONDecoder().decode([Item].self, from: data) { items = saved }
    }

    func add(_ item: Item) {
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        // The last 20. An untitled buffer pushed off goes as `forget` lets it go, History and all:
        // nothing else reached it, and it stayed for good (§8, 2026-10-03). A deleted file's
        // History stays with its path, which may have the file again.
        let pushed = Array(items.dropFirst(20))
        items.removeLast(pushed.count)
        persist()
        for item in pushed where item.untitled && Untitled.contains(URL(fileURLWithPath: item.path)) { Self.removeKept(for: item.path) }
    }

    func reopenLast() {
        // A file deleted since is skipped (opening it would make an empty one).
        items.removeAll { !$0.untitled && !FileManager.default.fileExists(atPath: $0.path) }
        persist()
        guard let item = items.first else { NSSound.beep(); return }
        reopen(item)
    }

    func reopen(_ item: Item) {
        items.removeAll { $0 == item }
        persist()
        if !item.untitled {
            AppDelegate.openFile(URL(fileURLWithPath: item.path))
            return
        }
        let history = History(root: NibPaths.support.appendingPathComponent("History"), path: item.path)
        guard let sha = item.sha256, let data = history.data(sha) else { NSSound.beep(); return }
        let url = URL(fileURLWithPath: item.path)
        // Back where it was, so its History goes on; under a new name if that one's taken, an
        // untitled buffer's History, caret and syntax carried there (left behind, nothing reached
        // them again). A deleted file's stay with its path.
        let taken = Set(Untitled.all().map(\.lastPathComponent))
        if !taken.contains(item.name), (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
           (try? data.write(to: url)) != nil {
            AppDelegate.openFile(url)
        } else if let fresh = Untitled.create(text: TextFile.decode(data).text) {
            if Untitled.contains(url) { FileCommands.carrySettings(from: url, to: fresh) }
            AppDelegate.openFile(fresh)
        }
    }

    /// At launch: untitled buffers closed over 30 days ago go, History and all (ED3).
    func sweep(now: Date = Date()) {
        let old = items.filter { $0.untitled && now.timeIntervalSince($0.time) > 30 * 86_400 }
        guard !old.isEmpty else { return }
        for item in old { forget(item) }
    }

    /// Off the list, and an untitled buffer's History with it.
    func forget(_ item: Item) {
        items.removeAll { $0 == item }
        persist()
        if item.untitled { Self.removeKept(for: item.path) }
    }

    /// What Nib keeps for an untitled buffer's path, gone: its History, caret and syntax. Not
    /// while the path is open (a deleted file's, back since and opened: its History goes on).
    static func removeKept(for path: String) {
        guard Documents.existing(for: URL(fileURLWithPath: path)) == nil else { return }
        let history = History(root: NibPaths.support.appendingPathComponent("History"), path: path)
        try? FileManager.default.removeItem(at: history.directory)
        NibDefaults.store.removeObject(forKey: "selection:" + path)
        NibDefaults.store.removeObject(forKey: "syntax:" + path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { NibDefaults.store.set(data, forKey: key) }
    }
}
