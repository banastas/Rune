// Zip archives read in memory (PRD HL3, L1): Sublime's `.sublime-package` files are zips, and
// Import from Sublime reads a scheme or its settings out of one without extracting anything.
// Stored and deflated entries; no ZIP64 (packages are far under 4 GB).

import Compression
import Foundation

public struct ZipArchive: Sendable {
    public struct Entry: Sendable {
        public let name: String
        let method: Int
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    private let bytes: [UInt8]
    public let entries: [String: Entry]

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 4 <= bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }
        // The end-of-central-directory record: the last 22 bytes, or up to 64 KB earlier with a comment.
        guard bytes.count >= 22 else { return nil }
        var end = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while end > lowest, u32(end) != 0x0605_4B50 { end -= 1 }
        guard u32(end) == 0x0605_4B50 else { return nil }
        let count = u16(end + 10)
        var at = u32(end + 16)
        var entries: [String: Entry] = [:]
        for _ in 0..<count {
            guard u32(at) == 0x0201_4B50 else { return nil }
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            guard at + 46 + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(name: name, method: u16(at + 10), compressedSize: u32(at + 20), size: u32(at + 24), headerOffset: u32(at + 42))
            at += 46 + nameLength + extra + comment
        }
        self.bytes = bytes
        self.entries = entries
    }

    /// An entry's contents, or nil if it isn't there or can't be read.
    public func contents(of name: String) -> Data? {
        guard let entry = entries[name] else { return nil }
        let at = entry.headerOffset
        guard at + 30 <= bytes.count, bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 3, bytes[at + 3] == 4 else { return nil }
        let nameLength = Int(bytes[at + 26]) | Int(bytes[at + 27]) << 8
        let extra = Int(bytes[at + 28]) | Int(bytes[at + 29]) << 8
        let start = at + 30 + nameLength + extra
        guard start + entry.compressedSize <= bytes.count else { return nil }
        switch entry.method {
        case 0:
            return Data(bytes[start..<(start + entry.compressedSize)])
        case 8:
            guard entry.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: entry.size)
            // Compression's ZLIB is raw DEFLATE (RFC 1951), which is what zip stores.
            let written = bytes[start..<(start + entry.compressedSize)].withUnsafeBufferPointer { source in
                compression_decode_buffer(&out, entry.size, source.baseAddress!, entry.compressedSize, nil, COMPRESSION_ZLIB)
            }
            return written == entry.size ? Data(out) : nil
        default:
            return nil
        }
    }
}
