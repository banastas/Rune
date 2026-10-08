// A text file's bytes and its on-disk form (PRD ED5): nib edits with "\n" line
// endings and writes the file back in the encoding, BOM, line endings and final
// newline it was read with, so opening and saving never rewrites what wasn't edited.

import Foundation

public enum LineEnding: String, Sendable, Codable, CaseIterable {
    case lf = "\n", crlf = "\r\n", cr = "\r"

    /// "LF", "CRLF", "CR" for the status strip.
    public var label: String {
        switch self {
        case .lf: "LF"
        case .crlf: "CRLF"
        case .cr: "CR"
        }
    }
}

public struct FileFormat: Sendable, Codable, Equatable {
    public enum Encoding: String, Sendable, Codable {
        case utf8, utf16LE, utf16BE, latin1

        var foundation: String.Encoding {
            switch self {
            case .utf8: .utf8
            case .utf16LE: .utf16LittleEndian
            case .utf16BE: .utf16BigEndian
            case .latin1: .isoLatin1
            }
        }

        var bom: [UInt8] {
            switch self {
            case .utf8: [0xEF, 0xBB, 0xBF]
            case .utf16LE: [0xFF, 0xFE]
            case .utf16BE: [0xFE, 0xFF]
            case .latin1: []
            }
        }

        /// "UTF-8", "UTF-16 LE", … for the status strip.
        public var label: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf16LE: "UTF-16 LE"
            case .utf16BE: "UTF-16 BE"
            case .latin1: "LATIN-1"
            }
        }
    }

    public var encoding: Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(encoding: Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    /// A new file: UTF-8, no BOM, LF.
    public static let standard = FileFormat()
}

public enum TextFile {
    /// Decodes a file's bytes into editing text ("\n" line endings) and the form to write it back in.
    /// Order: a BOM decides; otherwise UTF-8; otherwise Latin-1, which accepts any bytes.
    public static func decode(_ data: Data) -> (text: String, format: FileFormat) {
        let bytes = [UInt8](data.prefix(3))
        var encoding = FileFormat.Encoding.utf8
        var hasBOM = false
        for candidate in [FileFormat.Encoding.utf8, .utf16LE, .utf16BE] where bytes.starts(with: candidate.bom) {
            encoding = candidate
            hasBOM = true
            break
        }
        let body = hasBOM ? data.dropFirst(encoding.bom.count) : data[...]
        var raw = String(data: Data(body), encoding: encoding.foundation)
        if raw == nil, !hasBOM {
            encoding = .latin1
            raw = String(data: Data(body), encoding: .isoLatin1)
        }
        let text = raw ?? ""
        let ending = detectLineEnding(text)
        return (normalize(text), FileFormat(encoding: encoding, hasBOM: hasBOM, lineEnding: ending))
    }

    /// The bytes to write: "\n" turned back into the file's line ending, encoded, with its BOM.
    public static func encode(_ text: String, as format: FileFormat) -> Data {
        let body = format.lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.rawValue)
        var data = Data(format.hasBOM ? format.encoding.bom : [])
        data.append(body.data(using: format.encoding.foundation, allowLossyConversion: true) ?? Data())
        return data
    }

    /// The first line ending in the text decides; a file without one is LF.
    public static func detectLineEnding(_ text: String) -> LineEnding {
        for scalar in text.unicodeScalars.indices {
            switch text.unicodeScalars[scalar] {
            case "\r":
                let next = text.unicodeScalars.index(after: scalar)
                return next < text.unicodeScalars.endIndex && text.unicodeScalars[next] == "\n" ? .crlf : .cr
            case "\n":
                return .lf
            default:
                continue
            }
        }
        return .lf
    }

    /// Any mix of CRLF, CR and LF becomes LF. (Checked by byte: to Swift, "\r\n" is one
    /// Character, so `contains("\r")` misses it.)
    public static func normalize(_ text: String) -> String {
        // memchr over the bytes when they're contiguous (a native string): checking each byte in
        // Swift took tens of ms at 5 MB in a Debug build (§6.5).
        let carriageReturn = text.utf8.withContiguousStorageIfAvailable { bytes in
            bytes.baseAddress.map { memchr($0, 0x0D, bytes.count) != nil } ?? false
        } ?? text.utf8.contains(0x0D)
        guard carriageReturn else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
