// History (PRD SY13, §6.4, guarantee 2): every version of a file this Mac saved or took in,
// kept on this Mac for 30 days and thinned (all of the last day, one an hour for a week,
// one a day to 30 days), so any text Nib ever had can come back. Local only, never
// synced: it can hold secrets from the scratch file (§4.9, 23). Versions are stored once
// each, by SHA-256; an index in JSON Lines lists them with where each came from.

import Foundation
import NibText

public struct HistoryEntry: Codable, Sendable, Equatable {
    public var sha256: String
    /// The version it was made from, when known.
    public var parent: String?
    public var time: Date
    /// Where it came from: "saved", "from Air", "duplicate scratch 2.md", …
    public var source: String
    public var size: Int

    public init(sha256: String, parent: String?, time: Date, source: String, size: Int) {
        self.sha256 = sha256
        self.parent = parent
        self.time = time
        self.source = source
        self.size = size
    }
}

public final class History: Sendable {
    /// `<root>/<the file's key>/`: `index.jsonl` and `versions/<sha256>`.
    public let directory: URL
    private let lock = NSLock()

    public init(root: URL, path: String) {
        directory = root.appendingPathComponent(String(Digest.sha256(path).prefix(20)), isDirectory: true)
    }

    private var index: URL { directory.appendingPathComponent("index.jsonl") }
    private func versionURL(_ sha: String) -> URL { directory.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(sha) }

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

    /// Keeps `data` (once, by its SHA-256) and adds an entry, unless the newest entry is the
    /// same version already.
    public func record(_ data: Data, parent: String?, source: String, time: Date = Date()) throws {
        let sha = Digest.sha256(data)
        try lock.withLock {
            if let last = readEntries().last, last.sha256 == sha { return }
            try FileManager.default.createDirectory(at: versionURL(sha).deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: versionURL(sha).path) {
                try data.write(to: versionURL(sha), options: .atomic)
            }
            let entry = HistoryEntry(sha256: sha, parent: parent, time: time, source: source, size: data.count)
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: index) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: index, options: .atomic)
            }
        }
    }

    /// Oldest first.
    public func entries() -> [HistoryEntry] {
        lock.withLock { readEntries() }
    }

    private func readEntries() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    public func contains(_ sha: String) -> Bool {
        FileManager.default.fileExists(atPath: versionURL(sha).path)
    }

    /// The version's bytes, checked against its SHA-256.
    public func data(_ sha: String) -> Data? {
        guard let data = try? Data(contentsOf: versionURL(sha)), Digest.sha256(data) == sha else { return nil }
        return data
    }

    /// All of the last day, then the newest of each hour to a week, the newest of each day to
    /// 30 days, nothing older; versions no entry keeps any more are removed.
    public func thin(now: Date = Date()) {
        lock.withLock {
            let all = readEntries()
            var kept: [HistoryEntry] = [], buckets = Set<String>()
            for entry in all.reversed() {   // newest first, so each bucket keeps its newest
                let age = now.timeIntervalSince(entry.time)
                if age < 86_400 { kept.append(entry); continue }
                if age >= 30 * 86_400 { continue }
                let size: TimeInterval = age < 7 * 86_400 ? 3_600 : 86_400
                let bucket = "\(Int(size)):\(Int(entry.time.timeIntervalSince1970 / size))"
                if buckets.insert(bucket).inserted { kept.append(entry) }
            }
            kept.reverse()
            guard kept.count != all.count else { return }
            let lines = kept.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: index, atomically: true, encoding: .utf8)
            let keep = Set(kept.map(\.sha256))
            let folder = versionURL("x").deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
