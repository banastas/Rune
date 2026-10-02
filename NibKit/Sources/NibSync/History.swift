// History (PRD SY13, §6.4, guarantee 2): the versions of a file this Mac opened, took in,
// merged, restored or closed with, and the newest save of each five minutes (the document
// decides which, open question 22), kept on this Mac for 30 days and thinned (all of the last
// day, one an hour for a week, one a day to 30 days). Local only, never synced: it can hold
// secrets from the scratch file (§4.9, 23). Versions are stored once each, by SHA-256; an
// index in JSON Lines lists them with where each came from.

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
    /// Versions this Mac had and keeps no copy of, a line each ("<sha256> <time>"): let go by
    /// thinning, or never kept (`noteSeen`).
    private var thinned: URL { directory.appendingPathComponent("thinned.txt") }

    /// Whether this Mac had this version in the 30 days History covers: kept, let go by thinning
    /// since, or saved and not kept. For receipts (SY14): a version another Mac loaded a day ago,
    /// and thinned here since, isn't one this Mac hasn't seen (the suite, 2026-09-30: the Air's
    /// receipt from the day before read as "▼ NEWER ON BILL'S MACBOOK AIR · NOT HERE YET").
    public func has(_ sha: String) -> Bool {
        if contains(sha) { return true }
        // Searched as bytes, not split into lines: it has a line for each save of 30 days.
        // "<sha256> " can only match at a line's start.
        guard let lines = try? Data(contentsOf: thinned) else { return false }
        return lines.range(of: Data((sha + " ").utf8)) != nil
    }
    /// A version this Mac had and doesn't keep a copy of: a save between History's five-minute
    /// ones, or a big file's (open question 22, ED9). Known as seen for the 30 days History
    /// covers, as a thinned version is, so a receipt naming it isn't news (SY14). Appended here;
    /// `thin` folds it in with the rest.
    public func noteSeen(_ sha: String, time: Date = Date()) {
        lock.withLock {
            let line = Data("\(sha) \(ISO8601DateFormatter().string(from: time))\n".utf8)
            if let handle = try? FileHandle(forWritingTo: thinned) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? FileManager.default.createDirectory(at: thinned.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: thinned, options: .atomic)
            }
        }
    }

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
            let keep = Set(kept.map(\.sha256))
            remember(all.filter { !keep.contains($0.sha256) && now.timeIntervalSince($0.time) < 30 * 86_400 }, now: now)
            guard kept.count != all.count else { return }
            let lines = kept.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: index, atomically: true, encoding: .utf8)
            let folder = versionURL("x").deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    /// Adds the versions let go to `thinned` (the latest time each), and drops what's 30 days old.
    private func remember(_ gone: [HistoryEntry], now: Date) {
        let formatter = ISO8601DateFormatter()
        let old = (try? String(contentsOf: thinned, encoding: .utf8)) ?? ""
        var times: [String: Date] = [:]
        for line in old.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let time = formatter.date(from: String(parts[1])) else { continue }
            times[String(parts[0])] = max(time, times[String(parts[0])] ?? time)
        }
        for entry in gone { times[entry.sha256] = max(entry.time, times[entry.sha256] ?? entry.time) }
        times = times.filter { now.timeIntervalSince($0.value) < 30 * 86_400 }
        let lines = times.sorted { $0.value < $1.value }.map { "\($0.key) \(formatter.string(from: $0.value))\n" }.joined()
        guard lines != old else { return }
        if lines.isEmpty { try? FileManager.default.removeItem(at: thinned) } else { try? lines.write(to: thinned, atomically: true, encoding: .utf8) }
    }
}
