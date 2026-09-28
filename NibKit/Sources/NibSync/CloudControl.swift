// iCloud's sync controls (macOS 26+; PRD §4.3 "nib holds the file", §4.4 fetch).
// nib pauses iCloud's own syncing of a file it has open, uploads each version itself
// with fail-on-conflict (the server refuses an upload made from an old version),
// fetches newer versions when it becomes active, and resumes on close.
//
// Needs an app identity: from a bare command-line binary these calls fail with
// "feature not supported" (M0).

import Foundation

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
    }

    public enum FetchResult: Sendable, Equatable {
        /// Nothing newer on the server (or, for a file that isn't paused, iCloud replaced it itself).
        case current
        /// A newer version, already put in place of the local file; here are its bytes.
        case newer(data: Data, savedBy: String?, modified: Date?)
    }

    public enum ControlError: Error, Equatable {
        case unsupported
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

    /// Pauses iCloud's syncing of `url`. iCloud answers "resource busy" while it's still
    /// applying a change (M0 hit it right after an upload), so that retries with backoff.
    public static func pause(_ url: URL) async throws {
        var delay: Double = 0.5
        for attempt in 1...6 {
            do {
                try await FileManager.default.pauseSyncForUbiquitousItem(at: url)
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
        try await FileManager.default.resumeSyncForUbiquitousItem(
            at: url, with: mode == .uploadFailingOnConflict ? .afterUploadWithFailOnConflict : .dropLocalChanges)
    }

    /// "Upload now", refusing if the server has a newer version. Returns when iCloud has it.
    public static func upload(_ url: URL) async throws -> Date? {
        let version = try await FileManager.default.uploadLocalVersionOfUbiquitousItem(
            at: url, withConflictResolutionPolicy: .conflictPolicyFailOnConflict)
        return version.modificationDate
    }

    /// Asks the server for its newest version. While `url` is paused, a newer version
    /// arrives at a side location: its bytes are read there and it's put in place of the
    /// local file, so a following upload is based on it (the caller has the local edits
    /// in its buffer and journal, and merges before saving again).
    public static func fetchLatest(_ url: URL) async throws -> FetchResult {
        let version = try await FileManager.default.fetchLatestRemoteVersionOfItem(at: url)
        guard version.url.standardizedFileURL.path != url.standardizedFileURL.path else { return .current }
        let data = try FileAccess.read(version.url).data
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

    static func isUnsupported(_ error: Error) -> Bool {
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
