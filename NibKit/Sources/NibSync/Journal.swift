// The recovery journal (PRD SY1, §4.3 step 1): each buffer's latest text on this
// Mac's disk within 300 ms of a keystroke, so a crash, a force quit or a panic
// loses at most that. Local only, never synced. A snapshot counts only once it's
// fsynced and renamed into place (L3: record state only after the bytes are down).
//
// A big text (over a million characters: scratch files have reached 2.4 MB) is journaled as
// an edit log instead (§4.3, §4.9 row 24): a whole snapshot at most once a minute, and after
// each pause in typing only what changed since the last write, appended to the log beside the
// snapshot and fsynced, so typing writes bytes, not megabytes (a snapshot every pause was
// 2.4 MB, about 10 MB/s while typing). A save that leaves nothing unsaved appends a line
// saying so, where a small text's journal is deleted: deleting it would mean a new snapshot
// at the next pause, a save every few seconds. A torn last line (a crash mid-append) is
// ignored: the text as of the pause before.

import Darwin
import Foundation
import NibText
import Synchronization

public struct JournalEntry: Codable, Sendable, Equatable {
    /// The file this buffer belongs to.
    public var path: String
    public var text: String
    /// SHA-256 of `text`, checked on read: a snapshot that doesn't match is ignored.
    public var textSHA256: String
    /// The version the edits started from (the file's SHA-256 when it was loaded or last saved).
    public var baseSHA256: String?
    public var format: FileFormat
    public var written: Date

    public init(path: String, text: String, baseSHA256: String?, format: FileFormat, written: Date = Date()) {
        self.path = path
        self.text = text
        self.textSHA256 = Digest.sha256(text)
        self.baseSHA256 = baseSHA256
        self.format = format
        self.written = written
    }
}

public final class Journal: Sendable {
    public let directory: URL
    /// Texts longer than this (UTF-16 units) are journaled as edits after a snapshot.
    public static let logAbove = 1_000_000
    /// A snapshot serves its log this long, and the log grows to this many bytes at most.
    static let snapshotLife: TimeInterval = 60
    static let logLimit = 1_048_576

    /// Each big text as last journaled, by path: what the next change is measured from.
    private let logs = Mutex<[String: Log]>([:])

    struct Log: Sendable {
        var text: String
        var base: String?
        var format: FileFormat
        var since: Date
        var bytes: Int
        /// Everything journaled is in the file (a save left nothing unsaved).
        var clean = false
    }

    /// A line of the log. The first names the snapshot it follows; each after it is an edit
    /// (`cut` UTF-16 units at `at` replaced by `text`, leaving the text `length` long), the
    /// version the text is from (`base`, after a save), or that it's all in the file (`clean`).
    struct Line: Codable {
        var snapshot: String?
        var at: Int?
        var cut: Int?
        var text: String?
        var length: Int?
        var base: String?
        var clean: Bool?
        var written: Date?
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// One snapshot file per document path, and its log beside it.
    public func url(for path: String) -> URL {
        directory.appendingPathComponent(String(Digest.sha256(path).prefix(20)) + ".json")
    }

    public func logURL(for path: String) -> URL {
        url(for: path).deletingPathExtension().appendingPathExtension("log")
    }

    /// The buffer's text and the version it's from, journaled: a whole snapshot, or for a big
    /// text what changed since the last write, appended to the log. Blocking: call it on the
    /// journal's queue.
    public func record(path: String, text: String, baseSHA256: String?, format: FileFormat, now: Date = Date()) throws {
        let length = (text as NSString).length
        if length > Self.logAbove, let log = logs.withLock({ $0[path] }), log.format == format,
           now.timeIntervalSince(log.since) < Self.snapshotLife, log.bytes < Self.logLimit {
            var line = Line(written: now)
            if let change = TextDelta.change(from: log.text as NSString, to: text as NSString) {
                line.at = change.range.location
                line.cut = change.range.length
                line.text = change.replacement
                line.length = length
                line.base = baseSHA256
            } else if baseSHA256 != log.base {
                line.base = baseSHA256
            } else {
                return   // nothing new
            }
            let bytes = try append(line, for: path)
            logs.withLock {
                $0[path]?.text = text
                $0[path]?.base = baseSHA256
                $0[path]?.bytes += bytes
                if line.text != nil { $0[path]?.clean = false }
            }
            return
        }
        let entry = JournalEntry(path: path, text: text, baseSHA256: baseSHA256, format: format, written: now)
        try write(entry)
        guard length > Self.logAbove else { return }
        try start(after: entry)
        logs.withLock { $0[path] = Log(text: text, base: baseSHA256, format: format, since: now, bytes: 0) }
    }

    /// Temp file, fsync, rename over the previous snapshot, fsync the folder. A log after the
    /// last snapshot no longer applies.
    public func write(_ entry: JournalEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = url(for: entry.path)
        let temp = target.appendingPathExtension("tmp")
        let data = try JSONEncoder().encode(entry)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temp.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        syncFolder()
        try? FileManager.default.removeItem(at: logURL(for: entry.path))
        logs.withLock { $0[entry.path] = nil }
    }

    /// A new log, naming the snapshot it follows: a log left by a crash between the snapshot and
    /// this names the snapshot before, and is ignored.
    private func start(after entry: JournalEntry) throws {
        let data = try JSONEncoder().encode(Line(snapshot: entry.textSHA256)) + [0x0A]
        let url = logURL(for: entry.path)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        syncFolder()
    }

    /// A line at the end of the log, fsynced. Its size in bytes.
    private func append(_ line: Line, for path: String) throws -> Int {
        let data = try JSONEncoder().encode(line) + [0x0A]
        let handle = try FileHandle(forWritingTo: logURL(for: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return data.count
    }

    private func syncFolder() {
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 { fsync(folder); close(folder) }
    }

    /// The buffer's last journaled text for `path`, if it has anything the file may lack: the
    /// snapshot, with its log's edits made to it in order.
    public func read(path: String) -> JournalEntry? {
        guard let data = try? Data(contentsOf: url(for: path)),
              var entry = try? JSONDecoder().decode(JournalEntry.self, from: data),
              entry.path == path, Digest.sha256(entry.text) == entry.textSHA256 else { return nil }
        guard let log = try? Data(contentsOf: logURL(for: path)) else { return entry }
        let decoder = JSONDecoder()
        let lines = log.split(separator: 0x0A)
        guard let first = lines.first, (try? decoder.decode(Line.self, from: first))?.snapshot == entry.textSHA256 else { return entry }
        let text = NSMutableString(string: entry.text)
        var clean = false, edited = false
        for raw in lines.dropFirst() {
            guard let line = try? decoder.decode(Line.self, from: raw) else { break }   // torn: what came before stands
            if let at = line.at, let cut = line.cut, let replacement = line.text, let length = line.length {
                guard at >= 0, cut >= 0, at + cut <= text.length else { break }
                text.replaceCharacters(in: NSRange(location: at, length: cut), with: replacement)
                guard text.length == length else { break }
                edited = true
                clean = false
            }
            if line.clean == true { clean = true }
            if line.text != nil || line.base != nil { entry.baseSHA256 = line.base }
            if let written = line.written { entry.written = written }
        }
        if clean { return nil }
        if edited {
            entry.text = text as String
            entry.textSHA256 = Digest.sha256(entry.text)
        }
        return entry
    }

    /// The journal for `path` is gone: its document closed with nothing unsaved, or it had
    /// nothing to recover (a big text's clean log would otherwise stay, a 2.4 MB snapshot).
    public func remove(path: String) {
        logs.withLock { $0[path] = nil }
        try? FileManager.default.removeItem(at: url(for: path))
        try? FileManager.default.removeItem(at: logURL(for: path))
    }

    /// After a save has landed, the journal has nothing the file lacks. A big text's log says so
    /// (the next change is still measured from its snapshot); a small one's goes.
    public func clear(path: String) {
        if let log = logs.withLock({ $0[path] }) {
            guard !log.clean else { return }
            if let bytes = try? append(Line(clean: true, written: Date()), for: path) {
                logs.withLock {
                    $0[path]?.clean = true
                    $0[path]?.bytes += bytes
                }
                return
            }
        }
        remove(path: path)
    }
}
