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
        try? JSONEncoder().encode(paths).write(to: url, options: .atomic)
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
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
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
    public private(set) var firstUnsaved: Date?
    public private(set) var lastEdit: Date?

    public init(idle: TimeInterval = 1, maxWait: TimeInterval = 5) {
        self.idle = idle
        self.maxWait = maxWait
    }

    public mutating func edited(at time: Date = Date()) {
        if firstUnsaved == nil { firstUnsaved = time }
        lastEdit = time
    }

    /// The moment the pending edits are due on disk, or nil with nothing pending.
    public var due: Date? {
        guard let firstUnsaved, let lastEdit else { return nil }
        return min(lastEdit.addingTimeInterval(idle), firstUnsaved.addingTimeInterval(maxWait))
    }

    public mutating func saved() {
        firstUnsaved = nil
        lastEdit = nil
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
