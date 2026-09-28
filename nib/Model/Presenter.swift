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
