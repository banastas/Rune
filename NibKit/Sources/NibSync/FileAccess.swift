// Reading and saving a file the way nib's sync needs (PRD §4.3 steps 4-5):
// coordinated, off the main thread, and in place. A save is a compare-and-swap:
// inside one coordinated read-and-write, the file on disk is checked against the
// version the buffer came from, and only then rewritten, in the same file.
//
// In place, not a temp file renamed over it: M0 showed a rename makes a new file,
// which drops an iCloud sync pause and reaches file presenters as a deletion. A
// write torn by a crash is repaired from the journal.

import Darwin
import Foundation
import NibText

public enum WriteOutcome: Sendable, Equatable {
    /// Saved; the file is now this version.
    case written(Fingerprint)
    /// The file changed since the base version: nothing was written. Here is what's there.
    case diskChanged(data: Data, fingerprint: Fingerprint)
}

public enum FileAccess {
    /// Size, modification time and file ID, without reading the contents.
    public static func stat(_ url: URL) throws -> Fingerprint {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Fingerprint(size: Int64(info.st_size), modified: modified, fileID: UInt64(info.st_ino))
    }

    /// A coordinated read. On an evicted iCloud file this blocks until it downloads,
    /// so it must never run on the main thread (SY8).
    public static func read(_ url: URL, presenter: (any NSFilePresenter & Sendable)? = nil) throws -> (data: Data, fingerprint: Fingerprint) {
        var coordinationError: NSError?
        var result: Result<(Data, Fingerprint), Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                let data = try Data(contentsOf: target)
                var fingerprint = try stat(target)
                fingerprint.sha256 = Digest.sha256(data)
                return (data, fingerprint)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Compare-and-swap save. `base` is the version the buffer was loaded from or
    /// last saved as (nil for a file that doesn't exist yet). Passing the document's
    /// presenter keeps nib's own writes from notifying it.
    public static func write(_ data: Data, to url: URL, base: Fingerprint?,
                             presenter: (any NSFilePresenter & Sendable)? = nil) throws -> WriteOutcome {
        var coordinationError: NSError?
        var result: Result<WriteOutcome, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], writingItemAt: url, options: [],
                                                               error: &coordinationError) { readURL, writeURL in
            result = Result {
                let exists = FileManager.default.fileExists(atPath: writeURL.path)
                if exists {
                    let current = try stat(writeURL)
                    if base.map({ !current.sameStat(as: $0) }) ?? true {
                        // Changed stat fields (or a file where none was expected): the contents decide.
                        let onDisk = try Data(contentsOf: readURL)
                        let sha = Digest.sha256(onDisk)
                        if sha != base?.sha256 {
                            var fingerprint = current
                            fingerprint.sha256 = sha
                            return .diskChanged(data: onDisk, fingerprint: fingerprint)
                        }
                    }
                    try overwriteInPlace(writeURL, with: data)
                } else {
                    guard base == nil else {
                        // The file was there and is gone: deleted or moved elsewhere (§4.8 E).
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: writeURL.path])
                    }
                    try createFile(writeURL, with: data)
                }
                var fingerprint = try stat(writeURL)
                fingerprint.sha256 = Digest.sha256(data)
                return .written(fingerprint)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Same file, new contents: write from the start, cut to length, fsync. Writing
    /// before truncating means the file is never briefly empty.
    static func overwriteInPlace(_ url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func createFile(_ url: URL, with data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        try overwriteInPlace(url, with: data)
    }
}
