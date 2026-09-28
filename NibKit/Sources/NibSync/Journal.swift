// The recovery journal (PRD SY1, §4.3 step 1): each buffer's latest text on this
// Mac's disk within 300 ms of a keystroke, so a crash, a force quit or a panic
// loses at most that. Local only, never synced. A snapshot counts only once it's
// fsynced and renamed into place (L3: record state only after the bytes are down).

import Darwin
import Foundation
import NibText

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

    public init(directory: URL) {
        self.directory = directory
    }

    /// One snapshot file per document path.
    func url(for path: String) -> URL {
        directory.appendingPathComponent(String(Digest.sha256(path).prefix(20)) + ".json")
    }

    /// Temp file, fsync, rename over the previous snapshot, fsync the folder.
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
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 { fsync(folder); close(folder) }
    }

    /// The last good snapshot for `path`, if any.
    public func read(path: String) -> JournalEntry? {
        guard let data = try? Data(contentsOf: url(for: path)),
              let entry = try? JSONDecoder().decode(JournalEntry.self, from: data),
              entry.path == path, Digest.sha256(entry.text) == entry.textSHA256 else { return nil }
        return entry
    }

    /// After a save has landed, the snapshot has nothing the file lacks.
    public func clear(path: String) {
        try? FileManager.default.removeItem(at: url(for: path))
    }
}
