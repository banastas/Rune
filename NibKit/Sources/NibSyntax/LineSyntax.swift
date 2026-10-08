// CSV and logs (PRD HL8), which Sublime colors neither, in Nib's own colors and without a
// syntax tree: both are read a record or a line at a time, so a stretch is colored from the
// start of the record or line it starts in, exactly as the whole text is, and a 5 MB file
// costs nothing past its text.
//
// CSV: each field in its column's color, round six scopes An Old Hope · Nib colors apart
// (plain, red, yellow, green, cyan, orange; Rainbow CSV's ten would be white, red, white,
// grey, cyan, red, cyan, white, orange and green in it), the separators plain. A field that
// starts with a quote runs to its closing quote, over line breaks too (RFC 4180), so where a
// record starts depends on every quote before it: found by reading on from the last record
// start known (a document keeps one every 16K, up to its last edit). A .csv file's separator
// is whichever of comma, semicolon, tab and bar its first line has most of outside quotes (a
// comma if none), or the one Excel's `sep=;` first line names; a .tsv file's is a tab, and
// its quotes are text.
//
// Logs: in each line, timestamps dimmed as comments are, levels by severity (errors red,
// warnings yellow, information green, debugging dimmed), quoted strings, URLs, numbers and
// constants; the first to match at a place takes it (a number in a string or a timestamp is
// theirs). A line over 64K is left plain.

import Foundation

enum LineSyntax {
    private static let newline: UInt16 = 0x0A, quote: UInt16 = 0x22

    /// The spans of `units`, which sit at `offset` in the text, that touch `window` (in the
    /// text's terms). `records`: where CSV records start, as far as they're known.
    static func collect(_ units: UnsafeBufferPointer<UInt16>, offset: Int, language: SyntaxLanguage, root: String, level: Int,
                        window: NSRange, records: inout Records, into spans: inout [Highlighter.Span]) {
        let lo = max(0, window.location - offset), hi = min(units.count, NSMaxRange(window) - offset)
        guard hi > lo else { return }
        if language == .log {
            logSpans(units, offset: offset, from: lo, to: hi, level: level, into: &spans)
        } else {
            csvSpans(units, offset: offset, from: lo, to: hi, dialect: dialect(units, root: root), suffix: language.rawValue, level: level,
                     records: &records, into: &spans)
        }
    }

    // MARK: CSV

    struct Dialect: Equatable {
        var separator: UInt16
        /// A field that starts with a quote runs to its closing quote (CSV); a TSV's quotes are text.
        var quoted: Bool
    }

    /// Comma, semicolon, tab, bar: what a .csv file's first line has most of is its separator.
    static let separators: [UInt16] = [0x2C, 0x3B, 0x09, 0x7C]

    static func dialect(_ u: UnsafeBufferPointer<UInt16>, root: String) -> Dialect {
        if root.hasPrefix("text.tsv") { return Dialect(separator: 0x09, quoted: false) }
        var line = 0
        while line < min(u.count, 65_536), u[line] != newline { line += 1 }
        if line > 0, u[line - 1] == 0x0D { line -= 1 }
        // Excel's first line naming it: sep=;
        if line == 5, u[0] == 0x73, u[1] == 0x65, u[2] == 0x70, u[3] == 0x3D { return Dialect(separator: u[4], quoted: true) }
        var counts = [0, 0, 0, 0], inQuotes = false
        for i in 0..<line {
            if u[i] == quote { inQuotes.toggle() } else if !inQuotes, let k = separators.firstIndex(of: u[i]) { counts[k] += 1 }
        }
        var best = 0
        for k in 1..<counts.count where counts[k] > counts[best] { best = k }
        return Dialect(separator: separators[best], quoted: true)
    }

    /// The scopes the columns take in turn: plain, then what An Old Hope · Nib colors red,
    /// yellow, green, cyan and orange (a keyword, a function's name, a variable, a string, a
    /// number), so an imported scheme colors them apart too.
    static func columnScopes(_ suffix: String) -> [String] {
        ["meta.field.rainbow1", "keyword.other.rainbow2", "entity.name.function.rainbow3", "variable.other.rainbow4",
         "string.unquoted.rainbow5", "constant.numeric.rainbow6"].map { "\($0).\(suffix)" }
    }

    /// Where records start, as far as the text has been read: one every 16K or so, ascending,
    /// from 0, for the dialect they were read with. A document keeps them across edits: those
    /// past an edit go.
    struct Records {
        var marks = [0]
        var through = 0
        var dialect: Dialect?

        mutating func cut(at offset: Int) {
            while marks.count > 1, let last = marks.last, last > offset { marks.removeLast() }
            through = min(through, offset)
        }
    }

    /// The start of the record `target` is in: a TSV's line, or a CSV's record, read on from
    /// the last start known before it (its quotes decide where records end).
    static func recordStart(_ u: UnsafeBufferPointer<UInt16>, at target: Int, dialect: Dialect, records: inout Records) -> Int {
        guard dialect.quoted else {
            var i = target
            while i > 0, u[i - 1] != newline { i -= 1 }
            return i
        }
        if records.dialect != dialect { records = Records(dialect: dialect) }
        var low = 0, high = records.marks.count
        while low < high {
            let mid = (low + high) / 2
            if records.marks[mid] <= target { low = mid + 1 } else { high = mid }
        }
        var i = records.marks[low - 1], start = i, atFieldStart = true, inQuotes = false
        let n = u.count
        while i < target {
            let c = u[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n, u[i + 1] == quote { i += 2; continue }   // "" in a quoted field
                    inQuotes = false
                }
                i += 1
                continue
            }
            if atFieldStart, c == quote { inQuotes = true; atFieldStart = false; i += 1; continue }
            atFieldStart = c == dialect.separator || c == newline
            i += 1
            if c == newline {
                start = i
                if i > records.through, i - records.marks[records.marks.count - 1] >= 16_384 { records.marks.append(i) }
            }
        }
        records.through = max(records.through, i)
        return start
    }

    static func csvSpans(_ u: UnsafeBufferPointer<UInt16>, offset: Int, from lo: Int, to hi: Int, dialect: Dialect, suffix: String,
                         level: Int, records: inout Records, into spans: inout [Highlighter.Span]) {
        let n = u.count, scopes = columnScopes(suffix), separator = "punctuation.separator.sequence.\(suffix)"
        var i = recordStart(u, at: lo, dialect: dialect, records: &records)
        var column = 0, fieldStart = i, atFieldStart = true, inQuotes = false
        func field(to end: Int) {
            guard end > fieldStart, end > lo else { return }
            spans.append(Highlighter.Span(range: NSRange(location: offset + fieldStart, length: end - fieldStart),
                                          scope: scopes[column % scopes.count], order: (level, 0, spans.count)))
        }
        while i < hi {
            let c = u[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < n, u[i + 1] == quote { i += 2; continue }
                    inQuotes = false
                }
                i += 1
                continue
            }
            if atFieldStart, dialect.quoted, c == quote { inQuotes = true; atFieldStart = false; i += 1; continue }
            atFieldStart = false
            if c == dialect.separator || c == newline {
                field(to: i)
                if c == newline {
                    column = 0
                } else {
                    if i >= lo { spans.append(Highlighter.Span(range: NSRange(location: offset + i, length: 1), scope: separator, order: (level, 0, spans.count))) }
                    column += 1
                }
                i += 1
                fieldStart = i
                atFieldStart = true
                continue
            }
            i += 1
        }
        field(to: max(i, hi))   // the field the window ends in (it may run on past it)
    }

    // MARK: Logs

    /// What a log's tokens are, in the order that decides between two starting at one place.
    static let logScopes = ["comment.other.timestamp.log", "string.quoted", "markup.underline.link.log", "keyword.other.error.log",
                            "entity.name.function.warning.log", "variable.language.info.log", "comment.other.debug.log",
                            "constant.other.uuid.log", "constant.language.log", "constant.numeric.log"]
    private static let timestamp = 0, string = 1, url = 2, uuid = 7, constant = 8, number = 9

    static let timestampPattern: NSRegularExpression = {
        let month = "(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
        let time = #"\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?"#, zone = #"(?: ?(?:Z|[+-]\d{2}:?\d{2}))?"#
        let forms = [
            #"\d{4}[-/]\d{2}[-/]\d{2}(?:[T ]\d{1,2}:\d{2}(?::\d{2}(?:[.,]\d+)?)?\#(zone))?"#,   // 2026-10-02 17:24:01.123+0100
            #"\d{1,2}/\#(month)/\d{4}:\#(time)\#(zone)"#,                                       // [02/Oct/2026:17:24:01 +0000]
            #"(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),? )?\#(month) +\d{1,2},? \#(time)(?: \d{4})?"#, // Oct  2 17:24:01
            #"\d{1,2}/\d{1,2}/\d{4}(?:,? \#(time))?"#,                                           // 10/02/2026 17:24:01
            #"\#(time)\#(zone)"#,                                                                // 17:24:01.123
        ]
        return try! NSRegularExpression(pattern: #"(?<![\w:/-])(?:\#(forms.joined(separator: "|")))(?![\w:])"#)
    }()
    static let stringPattern = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*"|(?<!\w)'(?:[^'\\\n]|\\.)*'(?!\w)"#)
    static let numberPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.])(?:0[xX][0-9A-Fa-f]+\b|\d+(?:[.:]\d+)*(?:[eE][-+]?\d+)?(?:ms|µs|us|ns|s|m|h|d|[KMGTP]i?B|B|%)?(?!\w))"#)

    /// Levels as words in capitals or with a capital (ERROR, Warning), and in lower case where a
    /// level goes: [error], (warn, <info>, level=debug, error: …
    static let levels: (words: [String: Int], lower: [String: Int]) = {
        let kinds: [(String, String)] = [
            ("EMERGENCY EMERG ALERT CRITICAL CRIT FATAL PANIC SEVERE ERROR ERR FAILURE FAILED FAIL FAULT",
             "emergency critical fatal panic severe error err failure failed fault"),
            ("WARNING WARN", "warning warn"),
            ("INFORMATION INFO NOTICE", "information info notice"),
            ("DEBUG TRACE VERBOSE FINEST FINER FINE", "debug trace verbose"),
        ]
        var words: [String: Int] = [:], lower: [String: Int] = [:]
        for (k, (capitals, small)) in kinds.enumerated() {
            for word in capitals.split(separator: " ") { words[String(word)] = 3 + k }
            for word in small.split(separator: " ") {
                lower[String(word)] = 3 + k
                words[word.prefix(1).uppercased() + word.dropFirst()] = 3 + k
            }
        }
        return (words, lower)
    }()
    static let constants: Set<String> = ["true", "false", "True", "False", "TRUE", "FALSE", "null", "NULL", "nil", "None", "undefined", "NaN"]

    static func logSpans(_ u: UnsafeBufferPointer<UInt16>, offset: Int, from lo: Int, to hi: Int, level: Int, into spans: inout [Highlighter.Span]) {
        let n = u.count
        var start = lo
        while start > 0, u[start - 1] != newline { start -= 1 }
        var end = hi
        while end < n, u[end - 1] != newline { end += 1 }
        guard end > start, let base = u.baseAddress else { return }
        let text = NSString(characters: base + start, length: end - start) as String
        var line = start
        while line < end {
            var next = line
            while next < end, u[next] != newline { next += 1 }
            if next - line <= 65_536 {
                for token in logTokens(u, text: text, base: start, line: line, end: next) {
                    var scope = logScopes[token.kind]
                    if token.kind == string { scope += u[token.start] == quote ? ".double.log" : ".single.log" }
                    spans.append(Highlighter.Span(range: NSRange(location: offset + token.start, length: token.end - token.start),
                                                  scope: scope, order: (level, 0, spans.count)))
                }
            }
            line = next + 1
        }
    }

    /// A line's tokens: each kind found apart, then from the line's start the first at each place
    /// (the earliest kind where two start together), anything starting inside one left out.
    static func logTokens(_ u: UnsafeBufferPointer<UInt16>, text: String, base: Int, line: Int, end: Int) -> [(start: Int, end: Int, kind: Int)] {
        var found: [(start: Int, end: Int, kind: Int)] = []
        let range = NSRange(location: line - base, length: end - line)
        for (kind, pattern) in [(timestamp, timestampPattern), (string, stringPattern), (number, numberPattern)] {
            pattern.enumerateMatches(in: text, range: range) { match, _, _ in
                if let match { found.append((base + match.range.location, base + NSMaxRange(match.range), kind)) }
            }
        }
        func isWord(_ c: UInt16) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        func isHex(_ c: UInt16) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        func follows(_ word: String, before at: Int) -> Bool {
            let units = Array(word.utf16)
            return at - line >= units.count && units.indices.allSatisfy { u[at - units.count + $0] == units[$0] }
        }
        // URLs: a scheme (a letter, then letters, digits, + . -) before ://, and what follows up
        // to a space, a quote or a bracket, less a sentence's closing punctuation.
        var i = line
        while i + 2 < end {
            guard u[i] == 0x3A, u[i + 1] == 0x2F, u[i + 2] == 0x2F else { i += 1; continue }
            var s = i
            while s > line, isWord(u[s - 1]) && u[s - 1] != 0x5F || u[s - 1] == 0x2B || u[s - 1] == 0x2E || u[s - 1] == 0x2D { s -= 1 }
            var e = i + 3
            while e < end, !(u[e] == 0x20 || u[e] == 0x09 || u[e] == 0x0D || "\"'<>()[]{}".utf16.contains(u[e])) { e += 1 }
            while e > i + 3, ".,;:!?".utf16.contains(u[e - 1]) { e -= 1 }
            if s < i, isLetter(u[s]), s == line || !(isWord(u[s - 1]) || u[s - 1] == 0x2E || u[s - 1] == 0x2B || u[s - 1] == 0x2D), e > i + 3 {
                found.append((s, e, url))
                i = e
            } else {
                i += 3
            }
        }
        // Words: levels, constants, and UUIDs (8-4-4-4-12 hex digits).
        i = line
        while i < end {
            guard isWord(u[i]) else { i += 1; continue }
            let s = i
            while i < end, isWord(u[i]) { i += 1 }
            if i - s == 8, s == line || u[s - 1] != 0x2D, s + 36 <= end, (s + 36 == end || !(isWord(u[s + 36]) || u[s + 36] == 0x2D)),
               (s..<s + 36).allSatisfy({ [8, 13, 18, 23].contains($0 - s) ? u[$0] == 0x2D : isHex(u[$0]) }) {
                found.append((s, s + 36, uuid))
                i = s + 36
                continue
            }
            guard i - s >= 3, i - s <= 11, (s..<i).allSatisfy({ isLetter(u[$0]) }) else { continue }
            let word = String(decoding: UnsafeBufferPointer(rebasing: u[s..<i]), as: UTF16.self)
            if let kind = levels.words[word] {
                found.append((s, i, kind))
            } else if let kind = levels.lower[word],
                      (s > line && [0x5B, 0x3C, 0x28].contains(u[s - 1])) || (i < end && u[i] == 0x3A)
                        || follows("level=", before: s) || follows("lvl=", before: s) || follows("severity=", before: s) {
                found.append((s, i, kind))
            } else if constants.contains(word) {
                found.append((s, i, constant))
            }
        }
        found.sort { ($0.start, $0.kind) < ($1.start, $1.kind) }
        var taken: [(start: Int, end: Int, kind: Int)] = [], reached = line
        for token in found where token.start >= reached && token.end > token.start {
            taken.append(token)
            reached = token.end
        }
        return taken
    }
}
