// iCloud's sync controls (macOS 26+; PRD §4.3 "nib holds the file", §4.4 fetch).
// nib pauses iCloud's own syncing of a file it has open, uploads each version itself
// with fail-on-conflict (the server refuses an upload made from an old version),
// fetches newer versions when it becomes active, and resumes on close.
//
// Needs an app identity: from a bare command-line binary these calls fail with
// "feature not supported" (M0).

import Foundation
import NibText

public enum CloudControl {
    public struct Status: Sendable, Equatable {
        public var ubiquitous = false
        public var canPause = false
        public var canFailOnConflict = false
        public var paused: Bool?
        public var uploading = false
        public var uploaded = false
        public var downloading = false
        /// "current", "stale" (a newer version exists), "notDownloaded" (evicted), or "none".
        public var downloadStatus = "none"

        /// Nothing known: not ubiquitous, nothing offered.
        public init() {}
    }

    public enum FetchResult: Sendable, Equatable {
        /// Nothing newer on the server (or, for a file that isn't paused, iCloud replaced it itself).
        case current
        /// A newer version, already put in place of the local file; here are its bytes.
        case newer(data: Data, savedBy: String?, modified: Date?)
        /// iCloud offered a version the caller said to skip (by SHA-256): not put in place.
        case skipped(sha256: String)
    }

    public enum ControlError: Error, Equatable {
        case unsupported
        /// iCloud didn't answer in time (two-Mac test, 10:40: an upload racing another Mac's
        /// was still unanswered 35 s later). nib stops waiting and retries; iCloud may still
        /// finish the old call, and its late answer is ignored.
        case noAnswer(seconds: Double)
    }

    /// Runs `work`, giving up after `seconds`. Not a task group: a group waits for every
    /// child, and iCloud's calls can't be cancelled, so the wait would never end.
    public static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = Gate()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let value = try await work()
                    gate.once { continuation.resume(returning: value) }
                } catch {
                    gate.once { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.once { continuation.resume(throwing: ControlError.noAnswer(seconds: seconds)) }
            }
        }
    }

    public static func isNoAnswer(_ error: Error) -> Bool {
        if case ControlError.noAnswer = error { return true }
        return false
    }

    /// Fresh values every call (a new NSURL has no cached resource values).
    public static func status(_ url: URL) -> Status {
        let keys: [URLResourceKey] = [
            .isUbiquitousItemKey, .ubiquitousItemSupportedSyncControlsKey, .ubiquitousItemIsSyncPausedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        let values = (try? NSURL(fileURLWithPath: url.path).resourceValues(forKeys: keys)) ?? [:]
        func flag(_ key: URLResourceKey) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
        let controls = (values[.ubiquitousItemSupportedSyncControlsKey] as? NSNumber)?.intValue ?? 0
        var status = Status()
        status.ubiquitous = flag(.isUbiquitousItemKey)
        status.canPause = controls & 1 != 0
        status.canFailOnConflict = controls & 2 != 0
        status.paused = (values[.ubiquitousItemIsSyncPausedKey] as? NSNumber)?.boolValue
        status.uploading = flag(.ubiquitousItemIsUploadingKey)
        status.uploaded = flag(.ubiquitousItemIsUploadedKey)
        status.downloading = flag(.ubiquitousItemIsDownloadingKey)
        switch values[.ubiquitousItemDownloadingStatusKey] as? String {
        case URLUbiquitousItemDownloadingStatus.current.rawValue: status.downloadStatus = "current"
        case URLUbiquitousItemDownloadingStatus.downloaded.rawValue: status.downloadStatus = "stale"
        case URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue: status.downloadStatus = "notDownloaded"
        default: status.downloadStatus = "none"
        }
        return status
    }

    /// Whether the app's iCloud folder is there (setting it up on first use), or nil if iCloud
    /// doesn't answer in time: the call waits on iCloud Drive's daemon, and after a 2.4 MB file
    /// came and went a launch in the suite waited on it for good.
    public static func containerAvailable(_ id: String, within seconds: Double) async -> Bool? {
        try? await within(seconds) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: FileManager.default.url(forUbiquityContainerIdentifier: id) != nil)
                }
            }
        }
    }

    /// The file's iCloud state, or nil if iCloud doesn't answer in time: asking can wait on iCloud's
    /// file provider for good (a launch in the suite, after a 2.4 MB file came and went, waited
    /// in `status` until it was killed). Asked on a thread of its own, left to finish there.
    public static func status(_ url: URL, within seconds: Double) async -> Status? {
        try? await within(seconds) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: status(url)) }
            }
        }
    }

    /// Pauses iCloud's syncing of `url`. iCloud answers "resource busy" while it's still
    /// applying a change (M0 hit it right after an upload), so that retries with backoff.
    public static func pause(_ url: URL) async throws {
        var delay: Double = 0.5
        for attempt in 1...6 {
            do {
                try await within(20) { try await FileManager.default.pauseSyncForUbiquitousItem(at: url) }
                return
            } catch {
                if isUnsupported(error) { throw ControlError.unsupported }
                guard isBusy(error), attempt < 6 else { throw error }
                try await Task.sleep(for: .seconds(delay))
                delay *= 2
            }
        }
    }

    /// How to hand a paused file back to iCloud. There's deliberately no third way:
    /// `.preserveLocalChanges` lets iCloud "automatically pick the winner" when the server
    /// has a newer version (Apple's words), and in S1b a resume on one Mac replaced a
    /// version the other Mac had just uploaded, with no conflict copy. Never use it.
    public enum ResumeMode: Sendable {
        /// Unsent edits here: upload them first, and fail (as `isConflict`) if the server
        /// has a newer version, so nib merges instead of iCloud choosing.
        case uploadFailingOnConflict
        /// Everything here is already uploaded: take the server's newest version. Any local
        /// change iCloud finds is kept as an alternate version, not dropped.
        case takeServerVersion
    }

    public static func resume(_ url: URL, _ mode: ResumeMode) async throws {
        let behavior: NSFileManagerResumeSyncBehavior = mode == .uploadFailingOnConflict ? .afterUploadWithFailOnConflict : .dropLocalChanges
        try await within(20) { try await FileManager.default.resumeSyncForUbiquitousItem(at: url, with: behavior) }
    }

    /// "Upload now", refusing if the server has a newer version. Returns when iCloud has it.
    public static func upload(_ url: URL) async throws -> Date? {
        try await within(15) {
            let version = try await FileManager.default.uploadLocalVersionOfUbiquitousItem(
                at: url, withConflictResolutionPolicy: .conflictPolicyFailOnConflict)
            return version.modificationDate
        }
    }

    /// Asks the server for its newest version. While `url` is paused, a newer version
    /// arrives at a side location: its bytes are read there and it's put in place of the
    /// local file, so a following upload is based on it (the caller has the local edits
    /// in its buffer and journal, and merges before saving again).
    /// An iCloud conflict version of the file (§4.6, 3): edits made while Nib wasn't holding it,
    /// which iCloud kept beside the version it chose.
    public struct ConflictVersion: Sendable, Equatable {
        public var data: Data
        public var sha256: String
        public var savedBy: String?
        public var modified: Date?

        public init(data: Data, savedBy: String?, modified: Date?) {
            self.data = data
            self.sha256 = Digest.sha256(data)
            self.savedBy = savedBy
            self.modified = modified
        }
    }

    /// The file's unresolved conflict versions, read. A local query; the reads are coordinated,
    /// so off the main thread.
    public static func conflictVersions(_ url: URL) -> [ConflictVersion] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).compactMap { version in
            guard let data = try? FileAccess.read(version.url).data else { return nil }
            return ConflictVersion(data: data, savedBy: version.localizedNameOfSavingComputer, modified: version.modificationDate)
        }
    }

    /// Marks resolved the conflict versions with these contents, once their text is in the file
    /// (§4.7). Nothing is deleted: iCloud keeps them as ordinary versions, and History has them.
    public static func markResolved(_ url: URL, sha256s: Set<String>) {
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            guard let data = try? FileAccess.read(version.url).data, sha256s.contains(Digest.sha256(data)) else { continue }
            version.isResolved = true
        }
    }

    /// `skipping`: asked once iCloud has answered, which versions (by SHA-256) the caller knows
    /// to be stale then. Right after an upload iCloud can still offer the version that upload
    /// replaced (two-Mac tests at 14:20 and 15:05; at 15:05 the fetch began while the upload
    /// was still running, so the answer is what matters, not the question).
    public static func fetchLatest(_ url: URL, skipping: @escaping @Sendable () async -> Set<String> = { [] }) async throws -> FetchResult {
        try await within(15) { try await fetchLatestUnbounded(url, skipping: skipping) }
    }
    private static func fetchLatestUnbounded(_ url: URL, skipping: @Sendable () async -> Set<String>) async throws -> FetchResult {
        // The completion-handler form: iCloud can answer with neither a version nor an error,
        // and the async form traps on that (a crash at 21:15, M2). No version: nothing newer.
        // (The version only passes through here, one step after another: the box just carries it.)
        struct Answer: @unchecked Sendable { let version: NSFileVersion? }
        let answer: Answer = try await withCheckedThrowingContinuation { continuation in
            FileManager.default.fetchLatestRemoteVersionOfItem(at: url) { version, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: Answer(version: version)) }
            }
        }
        guard let version = answer.version, version.url.standardizedFileURL.path != url.standardizedFileURL.path else { return .current }
        let data = try FileAccess.read(version.url).data
        let sha = Digest.sha256(data)
        if await skipping().contains(sha) { return .skipped(sha256: sha) }
        let savedBy = version.localizedNameOfSavingComputer
        let modified = version.modificationDate
        _ = try version.replaceItem(at: url, options: [])
        return .newer(data: data, savedBy: savedBy, modified: modified)
    }

    /// The server refused an upload because it has a newer version
    /// (NSFileProviderErrorDomain -2015, `localVersionConflictingWithServer`).
    public static func isConflict(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == "NSFileProviderErrorDomain" && $0.code == -2015 }
    }

    static func isBusy(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == NSPOSIXErrorDomain && $0.code == Int(EBUSY) }
    }

    /// "Cannot be evicted" (-2008) or "unsynced edits" (-2007): iCloud isn't done with the file yet.
    static func isNotEvictableYet(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == "NSFileProviderErrorDomain" && ($0.code == -2008 || $0.code == -2007) }
    }

    /// iCloud storage is full (§4.9, 12): the upload would put the account over its quota.
    public static func isQuota(_ error: Error) -> Bool {
        chain(error).contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSUbiquitousFileNotUploadedDueToQuotaError)
                || ($0.domain == "NSFileProviderErrorDomain" && $0.code == -1003)   // insufficientQuota
        }
    }

    /// This Mac's disk is full (§4.9, 13).
    public static func isOutOfSpace(_ error: Error) -> Bool {
        chain(error).contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                || ($0.domain == NSPOSIXErrorDomain && ($0.code == Int(ENOSPC) || $0.code == Int(EDQUOT)))
        }
    }

    public static func isUnsupported(_ error: Error) -> Bool {
        chain(error).contains { $0.domain == NSCocoaErrorDomain && $0.code == CocoaError.featureUnsupported.rawValue }
    }

    /// The error and its underlying errors.
    static func chain(_ error: Error) -> [NSError] {
        var out: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, out.count < 8 {
            out.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return out
    }

    /// One line for the strip's tooltip and the Sync Log.
    public static func describe(_ error: Error) -> String {
        chain(error).map { "\($0.domain) \($0.code): \($0.localizedDescription)" }.joined(separator: " ← ")
    }
}

/// Resumes a continuation once, whichever side gets there first.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        action()
    }
}
