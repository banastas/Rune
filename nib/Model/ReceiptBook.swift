// This Mac's delivery receipts, published, and the other Macs', read (PRD SY14, §4.5). Each
// synced document says which version its buffer comes from whenever that changes; the
// folder's device file (`.nib/devices/<this Mac>.json`) is written at most every 5 s, and
// only when something changed. The other Macs' files are read when the folder changes (a
// watch on it, as for the notes), and fresh from the server when Nib comes forward and every
// 30 s while it's in front, with the note. File work is off the main thread (SY8), and every
// iCloud call has a time limit.

import AppKit
import NibSync

@MainActor
final class ReceiptBook {
    static let shared = ReceiptBook()

    /// The name the other Macs see, as the conflict labels and notes carry it.
    let device = Host.current().localizedName ?? "This Mac"

    /// This Mac's entries not written yet, and what it last said, by folder path and file name.
    private var pending: [String: [String: DeviceReceipts.Loaded]] = [:]
    private var said: [String: [String: String]] = [:]
    private var lastWrite: [String: Date] = [:]
    private var writing: Set<String> = []
    /// The other Macs' receipts, by folder path.
    private var others: [String: [DeviceReceipts]] = [:]
    private var watches: [String: DispatchSourceFileSystemObject] = [:]
    private var presenters: [String: ReceiptsPresenter] = [:]
    private var reading: Set<String> = []
    private var readAgain: Set<String> = []
    private let writes = IOQueue(label: "nib.receipts.write")
    private let reads = IOQueue(label: "nib.receipts.read")
    #if DEBUG
    /// Writes of this Mac's files so far, for the `receipts` scenario.
    private(set) var written = 0
    #endif

    static func folder(of url: URL) -> URL { DeviceReceipts.folder(for: url) }

    /// Only files in iCloud Drive have other Macs to hear from.
    static func applies(to url: URL) -> Bool {
        !Untitled.contains(url) && url.standardizedFileURL.path.hasPrefix(NSHomeDirectory() + "/Library/Mobile Documents/")
    }

    // MARK: This Mac's

    /// The document's buffer now comes from this version.
    func loaded(_ url: URL, sha: String) {
        guard Self.applies(to: url) else { return }
        let folder = Self.folder(of: url).path, name = url.lastPathComponent
        guard said[folder]?[name] != sha else { return }
        said[folder, default: [:]][name] = sha
        pending[folder, default: [:]][name] = .init(sha256: sha, time: Date())
        schedule(folder)
    }

    private func schedule(_ folder: String) {
        guard !writing.contains(folder) else { return }   // the write under way looks again after
        writing.insert(folder)
        let wait = max(0, 5 - Date().timeIntervalSince(lastWrite[folder] ?? .distantPast))
        Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            await write(folder)
        }
    }

    private func write(_ folder: String) async {
        let changes = pending.removeValue(forKey: folder) ?? [:]
        let device = self.device, place = URL(fileURLWithPath: folder, isDirectory: true)
        let writes = self.writes
        var failure: String?
        do {
            try await CloudControl.within(15) {
                try await writes.run {
                    let url = DeviceReceipts.url(in: place, device: device)
                    let current = DeviceReceipts.read(url) ?? DeviceReceipts(device: device)
                    try current.updated(with: changes, folder: place).write(to: url)
                }
            }
            #if DEBUG
            written += 1
            #endif
        } catch {
            failure = CloudControl.describe(error)
            // Kept for the next write; anything newer since wins.
            pending[folder, default: [:]].merge(changes) { newer, _ in newer }
        }
        lastWrite[folder] = Date()
        writing.remove(folder)
        if let failure { NSLog("Nib: couldn't write this Mac's receipts in \(folder): \(failure)") }
        if pending[folder]?.isEmpty == false { schedule(folder) }
    }

    /// Quitting: whatever is waiting for its 5 s is written now.
    func flush() async {
        for folder in Array(pending.keys) { await write(folder) }
    }

    // MARK: The other Macs'

    /// Watches the document's folder for the other Macs' receipts, and reads them.
    func watch(_ url: URL) {
        guard Self.applies(to: url) else { return }
        let folder = Self.folder(of: url)
        guard watches[folder.path] == nil else { return }
        let reads = self.reads
        Task {
            _ = try? await CloudControl.within(10) {
                await reads.run { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            }
            guard watches[folder.path] == nil else { return }
            let descriptor = Darwin.open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .attrib, .rename], queue: .main)
            source.setEventHandler {
                Task { @MainActor in await ReceiptBook.shared.read(folder.path, fresh: false) }
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            source.resume()
            watches[folder.path] = source
            // The watch sees files come and go; a presenter hears of one iCloud changes in place,
            // which leaves the folder as it was (the two-Mac test at 18:11 missed the Air's last).
            let presenter = ReceiptsPresenter(folder: folder)
            NSFileCoordinator.addFilePresenter(presenter)
            presenters[folder.path] = presenter
            await read(folder.path, fresh: false)
        }
    }

    private var timer: Timer?

    func becameActive() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await ReceiptBook.shared.refresh() }
        }
    }

    func resignedActive() {
        timer?.invalidate()
        timer = nil
    }

    /// The other Macs' receipts for the folders of the open documents, fresh from the server:
    /// when Nib comes forward, and every 30 s while it's in front.
    func refresh() async {
        for folder in Set(Documents.all.filter { Self.applies(to: $0.url) }.map { Self.folder(of: $0.url).path }) {
            await read(folder, fresh: true)
        }
    }

    fileprivate func read(_ folder: String, fresh: Bool) async {
        guard !reading.contains(folder) else { readAgain.insert(folder); return }
        reading.insert(folder)
        let device = self.device, place = URL(fileURLWithPath: folder, isDirectory: true)
        let reads = self.reads
        let found = try? await CloudControl.within(fresh ? 20 : 10) {
            await reads.run { DeviceReceipts.others(in: place, except: device, fresh: fresh) }
        }
        reading.remove(folder)
        if let found, found != (others[folder] ?? []) {
            others[folder] = found
            for document in Documents.all where Self.folder(of: document.url).path == folder { document.receiptsChanged() }
        }
        if readAgain.remove(folder) != nil { await read(folder, fresh: false) }
    }

    /// The other Macs' versions of a file: which Mac, and the version it has loaded, and when.
    /// Not one loaded more than 30 days ago (a Mac that's been away), as its own Nib would drop it.
    func others(for url: URL) -> [(device: String, loaded: DeviceReceipts.Loaded)] {
        (others[Self.folder(of: url).path] ?? []).compactMap { receipts in
            receipts.files[url.lastPathComponent].map { (receipts.device, $0) }
        }.filter { Date().timeIntervalSince($0.loaded.time) < DeviceReceipts.lifetime }
    }
}

/// The other Macs' receipts as iCloud brings them in: told of a file in the folder that appears
/// or changes, including one changed in place, which a watch on the folder doesn't see.
final class ReceiptsPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nib.receipts-presenter"
        return queue
    }()

    init(folder: URL) {
        presentedItemURL = folder
    }

    private func changed(_ url: URL) {
        guard url.pathExtension == "json", !url.lastPathComponent.hasPrefix("."), let folder = presentedItemURL?.path else { return }
        Task { @MainActor in await ReceiptBook.shared.read(folder, fresh: false) }
    }

    func presentedSubitemDidAppear(at url: URL) { changed(url) }
    func presentedSubitemDidChange(at url: URL) { changed(url) }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { changed(url) }
}
