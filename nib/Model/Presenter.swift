// The open file's NSFilePresenter (PRD §4.4). File coordination calls it on its own
// queue; everything is forwarded to the document on the main actor. iCloud also
// pushes upload and download state here, so nothing polls (A11).

import Foundation

final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL
    /// Set once by the document, read on the presenter queue.
    nonisolated(unsafe) weak var document: Document?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nib.presenter"
        return queue
    }()

    init(url: URL) {
        self.url = url
    }

    var presentedItemURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return url
    }

    var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> {
        [.ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
         .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSyncPausedKey]
    }

    private func forward(_ action: @escaping @MainActor (Document) async -> Void) {
        let document = self.document
        Task { @MainActor in if let document { await action(document) } }
    }

    func presentedItemDidChange() { forward { await $0.diskMayHaveChanged() } }
    func presentedItemDidGain(_ version: NSFileVersion) { forward { await $0.diskMayHaveChanged() } }
    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) { forward { $0.cloudAttributesChanged() } }

    /// Presenting `url` again: after a restore, the file is back where a move to the Trash took
    /// this presenter from (§4.8 E).
    func repoint(to url: URL) {
        lock.lock()
        self.url = url
        lock.unlock()
    }

    func presentedItemDidMove(to newURL: URL) {
        lock.lock()
        url = newURL
        lock.unlock()
        forward { $0.fileMoved(to: newURL) }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        forward { $0.fileWasDeleted() }
        completionHandler(nil)
    }
}

/// Watches the `.nib` folder that holds the "latest version" note (SY14): when another Mac
/// announces a version, the document checks whether it has it. The note is never paused,
/// so this arrives in seconds even while the document itself is held. It watches the
/// folder, not the note: a presenter isn't told when a file it presents is first created.
final class NotePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let noteName: String
    nonisolated(unsafe) weak var document: Document?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "nib.note-presenter"
        return queue
    }()

    /// `note` is the note file; the presenter watches its folder.
    init(note: URL) {
        presentedItemURL = note.deletingLastPathComponent()
        noteName = note.lastPathComponent
    }

    /// What's on disk: a fresh read evicts the note, and that was a change to hear of in turn
    /// (`Document.checkAnnouncement`).
    private func check(_ url: URL, _ reason: String) {
        guard url.lastPathComponent == noteName else { return }
        let document = self.document
        Task { @MainActor in await document?.checkAnnouncement(reason: reason, fresh: false) }
    }

    func presentedSubitemDidAppear(at url: URL) { check(url, "note appeared") }
    func presentedSubitemDidChange(at url: URL) { check(url, "note changed") }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { check(url, "note changed") }
}
