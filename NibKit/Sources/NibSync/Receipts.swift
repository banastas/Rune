// Delivery receipts (PRD SY14, §4.5): which version each Mac's Nib has loaded. For every synced
// file in a folder, the SHA-256 and time of the version its buffer comes from, in
// `<folder>/.nib/devices/<device>.json`: one file per Mac, written only by that Mac, never
// paused, so (like the notes beside it) it arrives in seconds while the documents themselves
// are held. It says "✓ ON STUDIO" (the other Mac has this very version) or "NEWER ON AIR, NOT
// HERE YET" (it has one this Mac hasn't seen). Receipts come through iCloud too, so they're as
// late as iCloud is. Each carries a format number, and one this Nib doesn't know is ignored,
// not misread (§4.8, row 21).

import Foundation

public struct DeviceReceipts: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public struct Loaded: Codable, Sendable, Equatable {
        public var sha256: String
        /// When that Mac loaded it, by its own clock (§4.5: each device's own times).
        public var time: Date

        public init(sha256: String, time: Date) {
            self.sha256 = sha256
            self.time = time
        }
    }

    public var format: Int
    public var device: String
    /// By file name, within the folder.
    public var files: [String: Loaded]

    public init(device: String, files: [String: Loaded] = [:]) {
        format = Self.currentFormat
        self.device = device
        self.files = files
    }

    /// `<folder>/.nib/devices/` for the document at `url`.
    public static func folder(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent(".nib", isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
    }

    /// A Mac's file in that folder: its name, with what a file name can't hold made "-".
    public static func url(in folder: URL, device: String) -> URL {
        let name = String(device.map { $0 == "/" || $0 == ":" || $0.isNewline ? "-" : $0 })
        return folder.appendingPathComponent((name.hasPrefix(".") ? "-" + name.dropFirst() : name) + ".json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    /// Decoded, or nil when it isn't a receipt of a format this Nib knows.
    public static func decode(_ data: Data) -> DeviceReceipts? {
        struct Header: Decodable { var format: Int }
        guard let header = try? decoder.decode(Header.self, from: data), header.format == currentFormat else { return nil }
        return try? decoder.decode(DeviceReceipts.self, from: data)
    }

    /// Written whole by a coordinated replace: this file is never paused, so a rename is fine.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoded()
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// A Mac's receipts, or nil. `fresh` asks the server rather than trusting the local copy,
    /// by evicting it and reading it back (as `Announcement.read` does, and for the same
    /// reason). Blocking: call it off the main thread.
    public static func read(_ url: URL, fresh: Bool = false) -> DeviceReceipts? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if fresh, (try? FileManager.default.evictUbiquitousItem(at: url)) != nil {
            for _ in 0..<20 where CloudControl.status(url).downloadStatus != "notDownloaded" {
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        guard let (data, _) = try? FileAccess.read(url) else { return nil }
        return decode(data)
    }

    /// Every other Mac's receipts in the folder. Blocking. Not `.skipsHiddenFiles`: iCloud marks
    /// the files in `.nib` hidden (the flag, not a dot), so that skipped every receipt that came
    /// from another Mac (the two-Mac test at 17:50, 2026-09-29). Names with a dot are skipped.
    public static func others(in folder: URL, except device: String, fresh: Bool = false) -> [DeviceReceipts] {
        let own = url(in: folder, device: device).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != own }
            .compactMap { read($0, fresh: fresh) }
            .filter { $0.device != device }
            .sorted { $0.device < $1.device }
    }

    /// How long an entry counts: History's 30 days, so a version older than that, which this Mac
    /// can't say it had, isn't taken for one it hasn't seen.
    public static let lifetime: TimeInterval = 30 * 86_400

    /// This Mac's receipts with `changes` in, dropping files that are gone from the folder and
    /// entries more than 30 days old.
    public func updated(with changes: [String: Loaded], folder: URL, now: Date = Date(),
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> DeviceReceipts {
        var next = self
        next.format = Self.currentFormat
        next.files.merge(changes) { _, new in new }
        let document = folder.deletingLastPathComponent().deletingLastPathComponent()
        next.files = next.files.filter { name, loaded in
            now.timeIntervalSince(loaded.time) < Self.lifetime && exists(document.appendingPathComponent(name))
        }
        return next
    }
}

/// Another Mac's version of a file, beside this Mac's (§4.5).
public enum Delivery: Equatable, Sendable {
    /// The same version: "✓ SYNCED · ON STUDIO 10:42:31".
    case same
    /// One this Mac hasn't seen: "▼ NEWER ON AIR (10:42) · NOT HERE YET".
    case newer
    /// One this Mac has seen and moved past (or merged in): the other Mac hasn't got this one yet.
    case earlier

    /// `base` is this Mac's version; `known` says whether this Mac has seen a version.
    public static func of(_ sha: String, base: String, known: (String) -> Bool) -> Delivery {
        sha == base ? .same : known(sha) ? .earlier : .newer
    }
}
