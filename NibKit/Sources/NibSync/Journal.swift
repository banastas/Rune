// The recovery journal (PRD SY1, §4.3 step 1): each buffer's latest text on this
// Mac's disk within 300 ms of a keystroke, so a crash, a force quit or a panic
// loses at most that. Local only, never synced. A snapshot counts only once it's
// fsynced and renamed into place (L3: record state only after the bytes are down).
//
// Each text is journaled as an edit log (§4.3, §4.9 row 24): a whole snapshot when its journal
// starts, and after each pause in typing only what changed since the last write, a line written
// into the log beside the snapshot and fsynced, so typing writes bytes, not the text. A new
// snapshot comes once the log reaches 1 MB. Big texts (over a million characters) had this from
// 2026-09-30, with a snapshot every minute; smaller ones wrote a whole snapshot every pause, and
// the scratch file at 223 KB meant about 260 KB a pause, a gigabyte or two an hour of typing as
// the kernel counts writes; and at 2.4 MB the minute's snapshots were 150 MB an hour (the
// disk-writes report of 2026-10-02, PRD §8). The log keeps room ahead of its lines (zeros, read
// as its end): a line written into it counts about 2 KB, appended (growing the file) about 17.
// A save that leaves nothing unsaved writes a line saying so: deleting the journal would mean a
// new snapshot at the next pause. A torn last line (a crash mid-write) is ignored: the text as
// of the pause before.

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
    /// A log grows to this many bytes of lines at most; then a new snapshot.
    static let logLimit = 1_048_576
    /// Room kept in the log ahead of its lines.
    static let logRoom = 65_536

    /// Each text as last journaled, by path: what the next change is measured from.
    private let logs = Mutex<[String: Log]>([:])

    struct Log: Sendable {
        var text: String
        var base: String?
        var format: FileFormat
        /// Bytes of lines after the first, against `logLimit`.
        var bytes: Int
        /// Where the next line goes, and the file's size (room included).
        var end: Int
        var room: Int
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

    /// The buffer's text and the version it's from, journaled: what changed since the last
    /// write, a line in the log, or a whole snapshot when the journal starts (or its log is
    /// full, or the text's format changed). Blocking: call it on the journal's queue.
    public func record(path: String, text: String, baseSHA256: String?, format: FileFormat, now: Date = Date()) throws {
        if let log = logs.withLock({ $0[path] }), log.format == format, log.bytes < Self.logLimit {
            var line = Line(written: now)
            if let change = TextDelta.change(from: log.text as NSString, to: text as NSString) {
                line.at = change.range.location
                line.cut = change.range.length
                line.text = change.replacement
                line.length = (text as NSString).length
                line.base = baseSHA256
            } else if baseSHA256 != log.base {
                line.base = baseSHA256
            } else {
                return   // nothing new
            }
            try append(line, for: path, kind: line.text == nil ? "journal base" : "journal edit")
            logs.withLock {
                $0[path]?.text = text
                $0[path]?.base = baseSHA256
                if line.text != nil { $0[path]?.clean = false }
            }
            return
        }
        let entry = JournalEntry(path: path, text: text, baseSHA256: baseSHA256, format: format, written: now)
        try write(entry)
        let (end, room) = try start(after: entry)
        logs.withLock { $0[path] = Log(text: text, base: baseSHA256, format: format, bytes: 0, end: end, room: room) }
    }

    /// Temp file, fsync, rename over the previous snapshot, fsync the folder. A log after the
    /// last snapshot no longer applies.
    public func write(_ entry: JournalEntry) throws {
        let mark = WriteMeter.start()
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
        WriteMeter.add("journal snapshot", bytes: data.count, since: mark)
    }

    /// A new log, naming the snapshot it follows: a log left by a crash between the snapshot and
    /// this names the snapshot before, and is ignored. Its end, and the file's size with room.
    private func start(after entry: JournalEntry) throws -> (end: Int, room: Int) {
        let mark = WriteMeter.start()
        let data = try JSONEncoder().encode(Line(snapshot: entry.textSHA256)) + [0x0A]
        let url = logURL(for: entry.path)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        let room = data.count + Self.logRoom
        try handle.truncate(atOffset: UInt64(room))
        try handle.synchronize()
        syncFolder()
        WriteMeter.add("journal log start", bytes: data.count, since: mark)
        return (data.count, room)
    }

    /// A line at the log's end, written into its room (more made when it runs out) and fsynced.
    private func append(_ line: Line, for path: String, kind: String) throws {
        guard let log = logs.withLock({ $0[path] }) else { return }
        let mark = WriteMeter.start()
        let data = try JSONEncoder().encode(line) + [0x0A]
        let handle = try FileHandle(forWritingTo: logURL(for: path))
        defer { try? handle.close() }
        var room = log.room
        if log.end + data.count > room {
            room = log.end + data.count + Self.logRoom
            try handle.truncate(atOffset: UInt64(room))
        }
        try handle.seek(toOffset: UInt64(log.end))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        logs.withLock {
            $0[path]?.end += data.count
            $0[path]?.room = room
            $0[path]?.bytes += data.count
        }
        WriteMeter.add(kind, bytes: data.count, since: mark)
    }

    /// The bytes of lines in the log for `path` as written, without its room (the `crash-big`
    /// scenario watches it grow).
    public func logBytes(for path: String) -> Int {
        guard let log = try? Data(contentsOf: logURL(for: path)) else { return 0 }
        return log.firstIndex(of: 0).map { $0 - log.startIndex } ?? log.count
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
            // Torn, or the room's zeros after the last line: what came before stands.
            guard let line = try? decoder.decode(Line.self, from: raw) else { break }
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
    /// nothing to recover (a clean log would otherwise stay, with its snapshot).
    public func remove(path: String) {
        logs.withLock { $0[path] = nil }
        try? FileManager.default.removeItem(at: url(for: path))
        try? FileManager.default.removeItem(at: logURL(for: path))
    }

    /// After a save has landed, the journal has nothing the file lacks. Its log says so (the next
    /// change is still measured from its snapshot); one that can't be written to goes.
    public func clear(path: String) {
        if let log = logs.withLock({ $0[path] }) {
            guard !log.clean else { return }
            if (try? append(Line(clean: true, written: Date()), for: path, kind: "journal clean")) != nil {
                logs.withLock { $0[path]?.clean = true }
                return
            }
        }
        remove(path: path)
    }
}
