// Plain-text paste (PRD PT1, PT3-PT5). ⌘V inserts the clipboard's text with "\n" line
// endings, nothing else (open question 7: plain text only). Paste Clean and Clean
// Clipboard go further: invisible characters out, unusual spaces made plain, trailing
// whitespace trimmed, and, if the setting is on, smart quotes and dashes straightened.

import Foundation

public enum PasteCleaner {
    /// What ⌘V inserts: the clipboard's plain text with "\n" line endings.
    public static func plain(_ text: String) -> String { TextFile.normalize(text) }

    public struct Options: Sendable, Equatable {
        /// ‘’ “” ′ ″ to ' and ", – — to - and --, … to ... (off by default, PT3).
        public var straightenQuotes = false
        public init(straightenQuotes: Bool = false) { self.straightenQuotes = straightenQuotes }
    }

    /// What was changed, for the confirmation ("CLIPBOARD CLEANED · 3 INVISIBLES REMOVED").
    public struct Result: Sendable, Equatable {
        public var text: String
        public var invisibles = 0
        public var spaces = 0
        public var trailing = 0
        public var quotes = 0

        public var changed: Bool { invisibles + spaces + trailing + quotes > 0 }

        /// The HUD's facts (W5), or "NOTHING TO CLEAN".
        public var facts: [String] {
            func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
            let parts = [count(invisibles, "INVISIBLE REMOVED", "INVISIBLES REMOVED"),
                         count(spaces, "SPACE MADE PLAIN", "SPACES MADE PLAIN"),
                         count(trailing, "LINE TRIMMED", "LINES TRIMMED"),
                         count(quotes, "QUOTE OR DASH STRAIGHTENED", "QUOTES AND DASHES STRAIGHTENED")].compactMap { $0 }
            return parts.isEmpty ? ["NOTHING TO CLEAN"] : parts
        }
    }

    /// Paste Clean: zero-width spaces, word joiners, the BOM, soft hyphens and bidi controls
    /// removed; zero-width joiners and non-joiners removed too, except between two non-ASCII
    /// characters, where they're doing their job (an emoji family, Persian or Indic text);
    /// non-breaking and other unusual spaces made plain; trailing whitespace trimmed.
    public static func clean(_ text: String, options: Options = Options()) -> Result {
        var result = Result(text: "")
        let scalars = Array(plain(text).unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x200B, 0x2060, 0xFEFF, 0x00AD, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x2061...0x2064, 0x180E:
                result.invisibles += 1
            case 0x200C, 0x200D:
                let before = i > 0 ? scalars[i - 1].value : 0, after = i + 1 < scalars.count ? scalars[i + 1].value : 0
                if before > 0x7F, after > 0x7F { out.append(scalar) } else { result.invisibles += 1 }
            case 0x00A0, 0x2007, 0x202F, 0x2000...0x200A, 0x3000, 0x205F:
                result.spaces += 1
                out.append(" ")
            default:
                if options.straightenQuotes, let straight = straightened[scalar.value] {
                    result.quotes += 1
                    out.append(contentsOf: straight.unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }
        // Trailing whitespace, line by line.
        var lines = String(out).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            var trimmed = Substring(line)
            while let last = trimmed.last, last == " " || last == "\t" { trimmed.removeLast() }
            if trimmed.count != line.count {
                result.trailing += 1
                lines[i] = String(trimmed)
            }
        }
        result.text = lines.joined(separator: "\n")
        return result
    }

    static let straightened: [UInt32: String] = [
        0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", 0x2032: "'",
        0x201C: "\"", 0x201D: "\"", 0x201E: "\"", 0x201F: "\"", 0x2033: "\"",
        0x2013: "-", 0x2014: "--", 0x2212: "-", 0x2026: "...",
    ]
}

/// Copy Block (PRD SC5): the fenced code block the caret is in (its code, without the
/// fences), or else the paragraph it's in (the lines between blank lines).
public enum TextBlocks {
    public enum Kind: Sendable, Equatable { case code, paragraph }

    public static func block(at location: Int, in text: String) -> (range: NSRange, kind: Kind)? {
        let s = text as NSString
        let caret = min(max(0, location), s.length)
        // The lines, with each fence line's state: inside a fence or not.
        var lines: [NSRange] = []
        var start = 0
        while start < s.length {
            let line = s.lineRange(for: NSRange(location: start, length: 0))
            lines.append(line)
            start = NSMaxRange(line)
        }
        if lines.isEmpty || (s.length > 0 && s.character(at: s.length - 1) == 0x0A) { lines.append(NSRange(location: s.length, length: 0)) }
        func content(_ line: NSRange) -> String {
            s.substring(with: line).trimmingCharacters(in: .newlines)
        }
        func isFence(_ line: NSRange) -> Bool {
            let t = content(line).trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("```") || t.hasPrefix("~~~")
        }
        guard let here = lines.firstIndex(where: { NSLocationInRange(caret, $0) || (caret == NSMaxRange($0) && NSMaxRange($0) == s.length) }) else { return nil }
        // Fenced blocks from the top, as pairs of fence lines: the caret on either fence or
        // between them is in that block.
        var open: Int?
        for (i, line) in lines.enumerated() where isFence(line) {
            guard let o = open else { open = i; continue }
            open = nil
            guard here >= o, here <= i else { continue }
            let first = NSMaxRange(lines[o]), end = lines[i].location
            guard end > first else { return nil }   // an empty block: nothing to copy
            var range = NSRange(location: first, length: end - first)
            if s.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }   // not the line break before the fence
            return (range, .code)
        }
        // The paragraph: the non-blank lines around the caret's.
        func blank(_ i: Int) -> Bool { content(lines[i]).trimmingCharacters(in: .whitespaces).isEmpty }
        guard !blank(here) else { return nil }
        var top = here, bottom = here
        while top > 0, !blank(top - 1), !isFence(lines[top - 1]) { top -= 1 }
        while bottom + 1 < lines.count, !blank(bottom + 1), !isFence(lines[bottom + 1]) { bottom += 1 }
        var range = NSRange(location: lines[top].location, length: NSMaxRange(lines[bottom]) - lines[top].location)
        if range.length > 0, s.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        return (range, .paragraph)
    }
}
