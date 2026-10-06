// Records nib keeps on this Mac (PRD §6.4): which files it has paused (a pause
// outlives the app, so launch settles the list, §4.9 14a), the Sync Log (every save,
// upload, fetch, merge and conflict, one JSON line each), and the save schedule.

import Foundation
import NibText

/// `paused.json`: every file nib has paused and not yet resumed.
public final class PausedFiles: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func all() -> [String] {
        guard let data = try? Data(contentsOf: url), let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths
    }

    public func add(_ path: String) { store(Array(Set(all() + [path])).sorted()) }

    public func remove(_ path: String) { store(all().filter { $0 != path }) }

    private func store(_ paths: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mark = WriteMeter.start()
        let data = (try? JSONEncoder().encode(paths)) ?? Data()
        try? data.write(to: url, options: .atomic)
        WriteMeter.add("paused list", bytes: data.count, since: mark)
    }
}

public struct SyncEvent: Codable, Sendable, Equatable {
    public var time: Date
    /// "open", "save", "upload", "fetch", "reload", "conflict", "resolve", "recover", "pause", "resume", "problem"
    public var event: String
    public var path: String
    public var device: String
    public var size: Int?
    public var sha256: String?
    public var ms: Int?
    public var detail: String?

    public init(_ event: String, path: String, device: String, size: Int? = nil, sha256: String? = nil,
                ms: Int? = nil, detail: String? = nil, time: Date = Date()) {
        self.time = time
        self.event = event
        self.path = path
        self.device = device
        self.size = size
        self.sha256 = sha256
        self.ms = ms
        self.detail = detail
    }
}

/// `sync.jsonl`, newest last (PRD SY13, A13).
public final class SyncLog: Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Posted after each line is written (on the writer's thread), for the Sync Log window.
    public static let didAppend = Notification.Name("NibSyncLogDidAppend")

    public init(url: URL) {
        self.url = url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public func append(_ event: SyncEvent) {
        guard var line = try? Self.encoder.encode(event) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mark = WriteMeter.start()
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
        WriteMeter.add("Sync Log", bytes: line.count, since: mark)
        NotificationCenter.default.post(name: Self.didAppend, object: nil)
    }

    public func read() -> [SyncEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(SyncEvent.self, from: Data($0.utf8)) }
    }
}

/// When to write the file (PRD SY2): 1 s after typing pauses, and at least every 5 s
/// while it doesn't.
public struct SaveSchedule: Sendable, Equatable {
    public var idle: TimeInterval
    public var maxWait: TimeInterval
    /// Bytes a second a file's saves write at most while typing goes on: after a save that wrote
    /// n bytes, the next waits n ÷ this. A save writes from the first byte that changed, so typing
    /// at the end of a file, or in a small one, isn't held back; typing near the top of 2.4 MB
    /// rewrote all of it every 4.5 s, about 2.6 GB an hour, and iCloud's daemons wrote several MB
    /// for each upload (2026-10-02, the user's call, PRD §8). Saves on a trigger don't wait.
    public var rate: Double
    public private(set) var firstUnsaved: Date?
    public private(set) var lastEdit: Date?
    /// The last save's bytes ÷ `rate` after it.
    public private(set) var notBefore: Date?

    public init(idle: TimeInterval = 1, maxWait: TimeInterval = 5, rate: Double = 80_000) {
        self.idle = idle
        self.maxWait = maxWait
        self.rate = rate
    }

    public mutating func wrote(_ bytes: Int, at time: Date = Date()) {
        notBefore = rate > 0 ? time.addingTimeInterval(Double(bytes) / rate) : nil
    }

    public mutating func edited(at time: Date = Date()) {
        if firstUnsaved == nil { firstUnsaved = time }
        lastEdit = time
    }

    /// The moment the pending edits are due on disk, or nil with nothing pending.
    public var due: Date? {
        guard let firstUnsaved, let lastEdit else { return nil }
        let due = min(lastEdit.addingTimeInterval(idle), firstUnsaved.addingTimeInterval(maxWait))
        return notBefore.map { max(due, $0) } ?? due
    }

    public mutating func saved() {
        firstUnsaved = nil
        lastEdit = nil
    }
}

/// When a held file's saves go up to iCloud (§4.3 step 7): on a trigger at once; otherwise once
/// typing has paused `pause` seconds, or `interval` after the last upload began while it goes on,
/// whichever comes first, and never within `spacing` of the last. Every upload sets iCloud's
/// daemons writing several MB of their own, besides Nib's note: 122 MB in 70 s while typing
/// went on, an upload every 4-5 s (2026-10-02, PRD §8). The user's call (2026-10-06): the other
/// Mac up to `interval` behind during a long stretch of typing, for a fifth of the uploads.
public struct UploadSchedule: Sendable, Equatable {
    public var pause: TimeInterval
    public var interval: TimeInterval
    public var spacing: TimeInterval
    public private(set) var lastEdit: Date?
    public private(set) var lastStart: Date?

    public init(pause: TimeInterval = 3, interval: TimeInterval = 20, spacing: TimeInterval = 3) {
        self.pause = pause
        self.interval = interval
        self.spacing = spacing
    }

    public mutating func edited(at time: Date = Date()) { lastEdit = time }
    public mutating func started(at time: Date = Date()) { lastStart = time }

    /// When an upload not asked for on a trigger should begin. The first goes at once.
    public var due: Date {
        guard let lastStart else { return .distantPast }
        let paused = (lastEdit ?? .distantPast).addingTimeInterval(pause)
        return max(lastStart.addingTimeInterval(spacing), min(paused, lastStart.addingTimeInterval(interval)))
    }
}

/// Where nib keeps its local records.
public enum NibPaths {
    /// The test harness's Nib (the suite, the two-Mac test and `run-perf.sh` launch it with
    /// -NibScenario), and the `nib` tool its `cli` scenario runs (NIB_SCENARIOS set): kept apart
    /// from the Nib in daily use, with a folder, settings and a bridge of their own, so that a
    /// test run never touches the user's journal, History, held files or lists (2026-10-01).
    public static let isScenario = ProcessInfo.processInfo.arguments.contains("-NibScenario")
        || ProcessInfo.processInfo.environment["NIB_SCENARIOS"] != nil

    /// `~/Library/Application Support/nib`, or the test harness's `nib-scenarios`.
    public static var support: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/" + (isScenario ? "nib-scenarios" : "nib"))
    }

    public static var iCloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs")
    }
}
