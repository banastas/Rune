// Untitled buffers (PRD ED3): File › New, ⌘N. Each is a file of Nib's own, on this Mac only
// (open question 12: local), at ~/Library/Application Support/nib/Untitled/<id>/Untitled 2,
// so the journal, saving, History and crash recovery work as for any file, and they come
// back after a quit or a crash (Sublime's hot exit). Nothing about them syncs, and they
// stay out of the Sync Log. Closing a non-empty one keeps its text in History for 30 days,
// and File › Reopen Closed File (⇧⌘T) brings it back; an empty one just goes (V8: no "Save?").
// File › Save… makes one a file.

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

    /// A new untitled buffer's file, named "Untitled", "Untitled 2"… (the lowest number free).
    static func create(text: String = "") -> URL? {
        let taken = Set(all().map(\.lastPathComponent))
        var name = "Untitled", n = 1
        while taken.contains(name) { n += 1; name = "Untitled \(n)" }
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
            if size == 0, !journaled { remove(url); continue }
            AppDelegate.openFile(url)
        }
    }

    /// Its window closed (not a quit): its text stays in History and on the Reopen Closed
    /// list for 30 days; an empty buffer just goes.
    static func discard(_ document: Document) {
        let url = document.url
        defer { remove(url) }
        guard !savedAway.contains(url.path) else { savedAway.remove(url.path); return }
        let text = document.editor.textView.string
        guard !text.isEmpty else { return }
        let data = TextFile.encode(text, as: document.format)
        try? document.history.record(data, parent: nil, source: "closed")
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: Digest.sha256(data), time: Date()))
    }

    private static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Buffers just saved as files: their text is in the file, so closing them keeps nothing.
    private static var savedAway: Set<String> = []

    // MARK: Save… (W3: the first save of an untitled document asks where)

    static func saveAs(_ document: Document) {
        let panel = NSSavePanel()
        panel.title = "Save “\(document.url.lastPathComponent)”"
        panel.nameFieldStringValue = document.url.lastPathComponent + ".txt"
        panel.directoryURL = ScratchLocation.url.deletingLastPathComponent()   // the test folder, until M1 passes (§8)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task { await save(document, to: target) }
    }

    /// Writes the buffer to `target` and opens that file in its place.
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
        savedAway.insert(document.url.path)
        let window = document.editor.textView.window
        AppDelegate.openFile(target)
        window?.performClose(nil)
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
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([Item].self, from: data) { items = saved }
    }

    func add(_ item: Item) {
        items.removeAll { $0.path == item.path }
        items.insert(item, at: 0)
        if items.count > 20 { items.removeLast(items.count - 20) }
        persist()
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
        // Back where it was, so its History goes on; under a new name if that one's taken.
        let taken = Set(Untitled.all().map(\.lastPathComponent))
        if !taken.contains(item.name), (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
           (try? data.write(to: url)) != nil {
            AppDelegate.openFile(url)
        } else if let fresh = Untitled.create(text: TextFile.decode(data).text) {
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
        guard item.untitled else { return }
        let history = History(root: NibPaths.support.appendingPathComponent("History"), path: item.path)
        try? FileManager.default.removeItem(at: history.directory)
        UserDefaults.standard.removeObject(forKey: "selection:" + item.path)
        UserDefaults.standard.removeObject(forKey: "syntax:" + item.path)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}
