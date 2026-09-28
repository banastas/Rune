// "This version is on the server" (PRD SY14, S1b): a tiny file beside the document,
// rewritten after every successful upload and never paused. S1b showed that a version
// reaching the server while a Mac holds the file paused is never applied on that Mac
// afterwards, and that iCloud keeps calling the stale copy current. Unpaused files arrive
// in seconds, so this one tells the other Macs what the newest version is.

import Foundation
import NibText

public struct Announcement: Codable, Sendable, Equatable {
    /// SHA-256 of the version now on the server.
    public var sha256: String
    /// The version it was made from (lineage, §4.6).
    public var parent: String?
    public var device: String
    public var time: Date
    public var size: Int

    public init(sha256: String, parent: String?, device: String, time: Date = Date(), size: Int) {
        self.sha256 = sha256
        self.parent = parent
        self.device = device
        self.time = time
        self.size = size
    }

    /// `<folder>/.nib/latest-<name>.json` for the document at `url`.
    public static func url(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent(".nib", isDirectory: true)
            .appendingPathComponent("latest-\(document.lastPathComponent).json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Written atomically: this file is never paused, so a rename is fine here.
    public func write(for document: URL) throws {
        let url = Self.url(for: document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(self)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Reads the note. `fresh` asks the server rather than trusting the local copy: it
    /// evicts the note and reads it back, which downloads the server's version (about a
    /// second). The two-Mac test at 10:00 showed a local copy that stayed old while the
    /// server had a newer one, as S1b found for the document itself; eviction is the one
    /// thing that reliably shows the server's version, and the note is tiny and never
    /// paused, so this is cheap. Blocking: call it off the main thread.
    public static func read(for document: URL, fresh: Bool = false) -> Announcement? {
        let url = Self.url(for: document)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if fresh, (try? FileManager.default.evictUbiquitousItem(at: url)) != nil {
            // Eviction completes asynchronously; then the coordinated read downloads it.
            for _ in 0..<20 where CloudControl.status(url).downloadStatus != "notDownloaded" {
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        guard let (data, _) = try? FileAccess.read(url) else { return nil }
        return try? decoder.decode(Announcement.self, from: data)
    }
}

extension CloudControl {
    /// Brings down the server's version of a file this Mac holds, when iCloud won't
    /// (S1b: fetch and both resume modes left a stale copy in place; eviction didn't).
    /// Hands the file back to iCloud taking the server's version, evicts it, and reads
    /// it back, which downloads it. The caller pauses it again. Only for a file with no
    /// unsaved edits: eviction refuses a file with changes iCloud doesn't have.
    public static func refetch(_ url: URL, wasPaused: Bool) async throws -> (data: Data, fingerprint: Fingerprint) {
        if wasPaused { try await resume(url, .takeServerVersion) }
        // Right after a resume iCloud can still be busy with the file (EBUSY): retry briefly.
        var delay = 0.25
        for attempt in 1...6 {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                break
            } catch {
                guard isBusy(error), attempt < 6 else { throw error }
                try await Task.sleep(for: .seconds(delay))
                delay *= 2
            }
        }
        // Eviction finishes asynchronously; the coordinated read waits for the download.
        for _ in 0..<40 where status(url).downloadStatus != "notDownloaded" {
            try await Task.sleep(for: .milliseconds(50))
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return try FileAccess.read(url)
    }
}
