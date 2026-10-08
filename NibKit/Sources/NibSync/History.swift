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
    /// Versions this Mac had and keeps no copy of, a line each ("<sha256> <time>"), oldest first:
    /// let go by thinning, or never kept (`noteSeen`).
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
            let mark = WriteMeter.start()
            let line = Data("\(sha) \(ISO8601DateFormatter().string(from: time))\n".utf8)
            if let handle = try? FileHandle(forWritingTo: thinned) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? FileManager.default.createDirectory(at: thinned.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: thinned, options: .atomic)
            }
            WriteMeter.add("History seen", bytes: line.count, since: mark)
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
                let mark = WriteMeter.start()
                try data.write(to: versionURL(sha), options: .atomic)
                WriteMeter.add("History version", bytes: data.count, since: mark)
            }
            let entry = HistoryEntry(sha256: sha, parent: parent, time: time, source: source, size: data.count)
            var line = try Self.encoder.encode(entry)
            line.append(0x0A)
            let mark = WriteMeter.start()
            if let handle = try? FileHandle(forWritingTo: index) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: index, options: .atomic)
            }
            WriteMeter.add("History index", bytes: line.count, since: mark)
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

    /// The version's bytes, not checked against its SHA-256: for Find in History (SY18), which
    /// only looks, and reads hundreds of versions in a row. Anything restored or merged reads
    /// `data`.
    public func unverifiedData(_ sha: String) -> Data? {
        try? Data(contentsOf: versionURL(sha), options: .mappedIfSafe)
    }

    /// The version's bytes, checked against its SHA-256.
    public func data(_ sha: String) -> Data? {
        guard let data = try? Data(contentsOf: versionURL(sha)), Digest.sha256(data) == sha else { return nil }
        return data
    }

    /// All of the last day, then the newest of each hour to a week, the newest of each day to
    /// 30 days, nothing older; versions no entry keeps any more are removed. True when it let any
    /// go. Run when a file opens and once a day while it stays open (its document's); with nothing
    /// due it reads the index and a line of `thinned`, and writes nothing.
    @discardableResult
    public func thin(now: Date = Date()) -> Bool {
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
            guard kept.count != all.count else { return false }
            let lines = kept.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            let mark = WriteMeter.start()
            let rewritten = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            try? rewritten.write(to: index, atomically: true, encoding: .utf8)
            WriteMeter.add("History thinning", bytes: rewritten.utf8.count, since: mark)
            let folder = versionURL("x").deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            return true
        }
    }

    /// Everything kept here goes to `destination`, the History of the path the text goes on at
    /// (Rename…, Move To…, an untitled buffer saved or renamed; guarantee 2): the folder moved when
    /// that path has none, merged into its when it has (the versions it lacks, the entries in time
    /// order, both lists of versions let go). Nothing stays here, where no path would open it
    /// again or thin it. The versions are linked, not copied, and this folder goes only once the
    /// merged index is written, so a crash on the way loses none. Not while either path is open.
    public func move(to destination: History) throws {
        let fm = FileManager.default
        guard destination.directory.standardizedFileURL.path != directory.standardizedFileURL.path else { return }
        try lock.withLock {
            try destination.lock.withLock {
                guard fm.fileExists(atPath: directory.path) else { return }
                guard fm.fileExists(atPath: destination.directory.path) else {
                    try fm.createDirectory(at: destination.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: directory, to: destination.directory)
                    return
                }
                let versions = versionURL("x").deletingLastPathComponent(), into = destination.versionURL("x").deletingLastPathComponent()
                try fm.createDirectory(at: into, withIntermediateDirectories: true)
                for name in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where !fm.fileExists(atPath: into.appendingPathComponent(name).path) {
                    try fm.linkItem(at: versions.appendingPathComponent(name), to: into.appendingPathComponent(name))
                }
                // Oldest first, as `record` keeps them; at the same moment, the destination's first.
                let entries = (destination.readEntries() + readEntries()).enumerated()
                    .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
                let lines = entries.compactMap { try? Self.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                try (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).write(to: destination.index, atomically: true, encoding: .utf8)
                var times = Self.times(in: destination.thinned)
                times.merge(Self.times(in: thinned)) { max($0, $1) }
                if !times.isEmpty {
                    var seen = ""   // oldest first, as `noteSeen` and `remember` keep it
                    seen.reserveCapacity(times.count * 86)
                    for (sha, time) in times.sorted(by: { $0.value < $1.value }) { seen += sha; seen += " "; seen += time; seen += "\n" }
                    try seen.write(to: destination.thinned, atomically: true, encoding: .utf8)
                }
                try fm.removeItem(at: directory)
            }
        }
    }

    /// A list of versions let go (`thinned`): each one's latest time, as written
    /// ("2026-10-02T12:34:56Z", always that long, so in time order as text). Not parsed: a month
    /// of saves is 100,000-200,000 lines, and parsing each one's time took seconds (2026-10-02).
    private static func times(in url: URL) -> [Substring: Substring] {
        let text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var times: [Substring: Substring] = [:]
        for bytes in text.utf8.split(separator: 0x0A) {
            // "<sha256> <time>": 64, a space, 20; a line of any other shape is a torn append.
            guard bytes.count == 85, bytes[bytes.index(bytes.startIndex, offsetBy: 64)] == 0x20 else { continue }
            let sha = Substring(bytes.prefix(64)), time = Substring(bytes.suffix(20))
            if let known = times[sha], known >= time { continue }
            times[sha] = time
        }
        return times
    }

    /// Adds the versions let go to `thinned` (the latest time each), and drops what's 30 days old.
    /// The file is in time order, oldest first (written so here; `noteSeen` adds the time it's
    /// called), so with nothing let go its first line says whether anything is 30 days old, and
    /// nothing more is read unless something is. Times are compared as written,
    /// "2026-10-02T12:34:56Z": always that long, so in time order as text. Parsing each line's took
    /// 6-15 s with a month of saves in the file (100,000-200,000 lines), History locked and the
    /// journal's queue waiting (2026-10-02, PRD §8); now 1-5 ms with nothing due, 70-230 ms with
    /// something (Release).
    private func remember(_ gone: [HistoryEntry], now: Date) {
        let formatter = ISO8601DateFormatter()
        let cutoff = formatter.string(from: Date(timeIntervalSince1970: (now.timeIntervalSince1970 - 30 * 86_400).rounded(.down)))
        if gone.isEmpty {
            guard let first = Self.firstLine(of: thinned) else { return }   // no file: nothing to drop
            if let time = Self.time(of: first), time > cutoff { return }
        }
        let old = (try? Data(contentsOf: thinned)).map { String(decoding: $0, as: UTF8.self) } ?? ""   // a bad byte costs its line only
        var lines: [(sha: Substring, time: Substring)] = []
        for bytes in old.utf8.split(separator: 0x0A) {
            let line = Substring(bytes)
            if let time = Self.time(of: line), time > cutoff { lines.append((Substring(line.utf8.prefix(64)), time)) }
        }
        for entry in gone {
            let time = formatter.string(from: entry.time)
            if time > cutoff { lines.append((Substring(entry.sha256), Substring(time))) }
        }
        lines.sort { $0.time < $1.time }   // in order already, but for the versions let go now
        var seen = Set<Substring>(), latest: [(sha: Substring, time: Substring)] = []
        for line in lines.reversed() where seen.insert(line.sha).inserted { latest.append(line) }   // each version's latest line
        var text = ""
        text.reserveCapacity(latest.count * 86)
        for line in latest.reversed() { text += line.sha; text += " "; text += line.time; text += "\n" }
        guard text != old else { return }
        let mark = WriteMeter.start()
        if text.isEmpty { try? FileManager.default.removeItem(at: thinned) } else { try? text.write(to: thinned, atomically: true, encoding: .utf8) }
        WriteMeter.add("History thinning", bytes: text.utf8.count, since: mark)
    }

    /// The time on a line of `thinned`, as written; nil for a line of any other shape (a torn append).
    private static func time(of line: Substring) -> Substring? {
        let bytes = line.utf8   // "<sha256> <time>": 64, a space, 20
        guard bytes.count == 85, bytes[bytes.index(bytes.startIndex, offsetBy: 64)] == 0x20 else { return nil }
        return Substring(bytes.suffix(20))
    }

    private static func firstLine(of url: URL) -> Substring? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 128), !head.isEmpty else { return nil }
        return String(decoding: head, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
    }
}
