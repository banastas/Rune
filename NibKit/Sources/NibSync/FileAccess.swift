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
    /// Saved; the file is now this version, `changed` bytes of it written (only what differed).
    case written(Fingerprint, changed: Int)
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
                var changed = 0
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
                    changed = try overwriteInPlace(writeURL, with: data)
                } else {
                    guard base == nil else {
                        // The file was there and is gone: deleted or moved elsewhere (§4.8 E).
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: writeURL.path])
                    }
                    changed = try createFile(writeURL, with: data)
                }
                var fingerprint = try stat(writeURL)
                fingerprint.sha256 = Digest.sha256(data)
                return .written(fingerprint, changed: changed)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Same file, new contents, written from the first byte that differs from what's there (and,
    /// the same length, only to the last that differs), then cut to length and fsynced. Writing
    /// before truncating means the file is never briefly empty. A save had written the whole
    /// file: typing at the end of 2.4 MB, 2.4 MB a save, a save a second after each pause, about
    /// 1.7 GB an hour of steady typing; the end alone is about 20 KB as the kernel counts it
    /// (2026-10-02, PRD §8). Returns the bytes written.
    @discardableResult
    static func overwriteInPlace(_ url: URL, with data: Data) throws -> Int {
        let mark = WriteMeter.start()
        let handle = try FileHandle(forUpdating: url)
        do {
            let size = Int(try handle.seekToEnd())
            let changed = try stretch(of: data, differingFrom: handle, size: size)
            if !changed.isEmpty {
                try handle.seek(toOffset: UInt64(changed.lowerBound))
                try handle.write(contentsOf: data[data.startIndex + changed.lowerBound ..< data.startIndex + changed.upperBound])
            }
            if size != data.count { try handle.truncate(atOffset: UInt64(data.count)) }
            if !changed.isEmpty || size != data.count { try handle.synchronize() }
            try handle.close()
            WriteMeter.add("file", bytes: changed.count, since: mark)
            return changed.count
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// The bytes of `data` that differ from the file's `size` bytes: from the first that differs
    /// to the end, or, the same length, to the last that differs. Read a megabyte at a time.
    static func stretch(of data: Data, differingFrom handle: FileHandle, size: Int) throws -> Range<Int> {
        let chunk = 1 << 20
        var from = 0
        try handle.seek(toOffset: 0)
        while from < min(size, data.count) {
            let count = min(chunk, min(size, data.count) - from)
            guard let disk = try handle.read(upToCount: count), disk.count == count else { break }   // shorter than it was: written from here
            if let at = difference(disk, data, at: from, backward: false) { from += at; break }
            from += count
        }
        guard size == data.count, from < size else { return from ..< data.count }
        var to = size
        while to > from {
            let count = min(chunk, to - from)
            try handle.seek(toOffset: UInt64(to - count))
            guard let disk = try handle.read(upToCount: count), disk.count == count else { break }
            if let at = difference(disk, data, at: to - count, backward: true) { to = to - count + at + 1; break }
            to -= count
        }
        return from ..< to
    }

    /// Where `disk` and the same stretch of `data` from `offset` first differ (or, backward, last),
    /// by 4 KB blocks with `memcmp`, then bytes; nil where they're the same.
    private static func difference(_ disk: Data, _ data: Data, at offset: Int, backward: Bool) -> Int? {
        disk.withUnsafeBytes { a in
            data.withUnsafeBytes { whole in
                let b = UnsafeRawBufferPointer(rebasing: whole[offset ..< offset + a.count])
                guard let pa = a.baseAddress, let pb = b.baseAddress else { return nil }
                let block = 4096
                var blocks = Array(stride(from: 0, to: a.count, by: block))
                if backward { blocks.reverse() }
                for start in blocks {
                    let count = min(block, a.count - start)
                    guard memcmp(pa + start, pb + start, count) != 0 else { continue }
                    let bytes = backward ? Array((start ..< start + count).reversed()) : Array(start ..< start + count)
                    return bytes.first { a[$0] != b[$0] }
                }
                return nil
            }
        }
    }

    static func createFile(_ url: URL, with data: Data) throws -> Int {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        return try overwriteInPlace(url, with: data)
    }
}
