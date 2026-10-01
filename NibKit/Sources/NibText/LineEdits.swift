// Sublime's line commands (PRD ED6, KB4, §5.12), as edits on the text: each gives the range
// to replace, what goes there, and the selection after, so the editor applies it as one
// undoable change. Indentation per file (tabs, or so many spaces), detected on open.

import Foundation

public struct LineEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange
}

/// How a file indents: with tabs, or with so many spaces.
public enum Indentation: Sendable, Equatable {
    case tabs(width: Int)
    case spaces(Int)

    public var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces(let n): String(repeating: " ", count: n)
        }
    }

    public var width: Int {
        switch self {
        case .tabs(let width): width
        case .spaces(let n): n
        }
    }

    /// From the file: tabs if most indented lines start with one, else the common step of the
    /// spaces (2, 4…); `fallback` for a file with nothing indented.
    public static func detect(in text: String, fallback: Indentation) -> Indentation {
        var tabs = 0, spaced: [Int] = []
        // The first 5,000 lines only, split no further: `split` makes every line first, and
        // `prefix` came after (1 s of a 5 MB file's open, Debug; §6.5, 2026-09-30).
        for line in text.split(separator: "\n", maxSplits: 5_000, omittingEmptySubsequences: true).prefix(5_000) {
            if line.hasPrefix("\t") { tabs += 1; continue }
            let n = line.prefix { $0 == " " }.count
            if n > 0, n < line.count { spaced.append(n) }
        }
        if tabs == 0, spaced.isEmpty { return fallback }
        if tabs >= spaced.count { return .tabs(width: fallback.width) }
        // The smallest step most lines agree with: 2 when some lines sit at 2, 6 or 10, else 4…
        for step in [2, 4, 8, 3] where spaced.filter({ $0 % step != 0 }).count * 10 <= spaced.count {
            if step == 2, !spaced.contains(where: { $0 % 4 != 0 }) { return .spaces(4) }
            return .spaces(step)
        }
        return .spaces(spaced.min() ?? 4)
    }
}

/// A language's comment: per line (`//`, `#`), or around the lines (`/* */`, `<!-- -->`).
public enum CommentStyle: Sendable, Equatable {
    case line(String)
    case block(String, String)
}

public enum LineEdits {
    /// The whole lines a selection touches, with their line breaks (a selection ending at a
    /// line's start doesn't take that line).
    public static func lines(of selection: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(selection)
        if selection.length > 0, end > selection.location, end <= text.length, text.character(at: end - 1) == 0x0A { end -= 1 }
        let first = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let last = text.lineRange(for: NSRange(location: max(selection.location, end), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }

    /// Duplicate Line (⇧⌘D): the lines below themselves, the caret on the copy; with a
    /// selection inside one line, the selection after itself, selected.
    public static func duplicate(_ text: String, selection: NSRange) -> LineEdit {
        let s = text as NSString
        if selection.length > 0, !s.substring(with: selection).contains("\n") {
            let copy = s.substring(with: selection)
            return LineEdit(range: NSRange(location: NSMaxRange(selection), length: 0), replacement: copy,
                            selection: NSRange(location: NSMaxRange(selection), length: selection.length))
        }
        let lines = lines(of: selection, in: s)
        let block = s.substring(with: lines)
        // The last line has no break: one goes before the copy.
        let inserted = block.hasSuffix("\n") ? block : "\n" + block
        let shift = (inserted as NSString).length
        return LineEdit(range: NSRange(location: NSMaxRange(lines), length: 0), replacement: inserted,
                        selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// Move Line Up / Down (⌃⌘↑ / ⌃⌘↓): the lines swap with the one above or below; the
    /// selection moves with them. Nil at the top or bottom.
    public static func move(_ text: String, selection: NSRange, up: Bool) -> LineEdit? {
        let s = text as NSString
        let lines = lines(of: selection, in: s)
        if up {
            guard lines.location > 0 else { return nil }
            let above = s.lineRange(for: NSRange(location: lines.location - 1, length: 0))
            var moving = s.substring(with: lines), other = s.substring(with: above)
            if !moving.hasSuffix("\n") { moving += "\n"; other.removeLast() }   // the last line has no break
            let whole = NSRange(location: above.location, length: NSMaxRange(lines) - above.location)
            return LineEdit(range: whole, replacement: moving + other,
                            selection: NSRange(location: selection.location - above.length, length: selection.length))
        } else {
            guard NSMaxRange(lines) < s.length else { return nil }
            let below = s.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            var moving = s.substring(with: lines), other = s.substring(with: below)
            if !other.hasSuffix("\n") { other += "\n"; moving.removeLast() }
            let whole = NSRange(location: lines.location, length: NSMaxRange(below) - lines.location)
            return LineEdit(range: whole, replacement: other + moving,
                            selection: NSRange(location: selection.location + (other as NSString).length, length: selection.length))
        }
    }

    /// Select Line (⌘L): the caret's whole line; again, the next line too.
    public static func selectLine(_ text: String, selection: NSRange) -> NSRange {
        let s = text as NSString
        let lines = lines(of: selection, in: s)
        let whole = selection.length > 0 && selection == lines
        guard whole, NSMaxRange(lines) < s.length else { return lines }
        let next = s.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
        return NSRange(location: lines.location, length: NSMaxRange(next) - lines.location)
    }

    /// Join Lines (⌘J): the next line onto this one, its indentation made one space; with a
    /// selection over several lines, all of them. Nil on the last line.
    public static func join(_ text: String, selection: NSRange) -> LineEdit? {
        let s = text as NSString
        var lines = lines(of: selection, in: s)
        let single = s.substring(with: lines).trimmingCharacters(in: .newlines).contains("\n") == false
        if single {
            guard NSMaxRange(lines) < s.length else { return nil }
            let next = s.lineRange(for: NSRange(location: NSMaxRange(lines), length: 0))
            lines.length = NSMaxRange(next) - lines.location
        }
        var body = s.substring(with: lines)
        let ending = body.hasSuffix("\n") ? "\n" : ""
        if !ending.isEmpty { body.removeLast() }
        let parts = body.components(separatedBy: "\n")
        var joined = parts[0]
        for part in parts.dropFirst() {
            let trimmed = part.drop { $0 == " " || $0 == "\t" }
            while joined.hasSuffix(" ") || joined.hasSuffix("\t") { joined.removeLast() }
            joined += trimmed.isEmpty ? "" : " " + trimmed
        }
        // The caret at the join: after the first line's text, its trailing spaces gone.
        var head = parts[0]
        while head.hasSuffix(" ") || head.hasSuffix("\t") { head.removeLast() }
        let caret = lines.location + (head as NSString).length
        return LineEdit(range: lines, replacement: joined + ending, selection: NSRange(location: min(caret, lines.location + (joined as NSString).length), length: 0))
    }

    /// Indent (⌘]): one unit at the start of each non-blank line; Outdent (⌘[): up to one off.
    public static func indent(_ text: String, selection: NSRange, unit: String, outdent: Bool = false, width: Int = 4) -> LineEdit? {
        let s = text as NSString
        let lines = lines(of: selection, in: s)
        var body = s.substring(with: lines)
        let ending = body.hasSuffix("\n") ? "\n" : ""
        if !ending.isEmpty { body.removeLast() }
        var changedFirst = 0, total = 0
        let out = body.components(separatedBy: "\n").enumerated().map { (i, line) -> String in
            if outdent {
                var removed = 0
                var rest = Substring(line)
                if rest.hasPrefix("\t") { rest.removeFirst(); removed = 1 }
                else { while removed < width, rest.hasPrefix(" ") { rest.removeFirst(); removed += 1 } }
                if i == 0 { changedFirst = -removed }
                total -= removed
                return String(rest)
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if i == 0 { changedFirst = (unit as NSString).length }
            total += (unit as NSString).length
            return unit + line
        }.joined(separator: "\n")
        guard total != 0 else { return nil }
        let start = max(lines.location, selection.location + changedFirst)
        let length = max(0, selection.length + total - changedFirst)
        return LineEdit(range: lines, replacement: out + ending,
                        selection: NSRange(location: start, length: selection.length == 0 ? 0 : min(length, (out as NSString).length + (ending as NSString).length)))
    }

    /// Toggle Comment (⌘/): uncommented if every non-blank line is commented, else commented;
    /// a line comment at the lines' least indentation, a block around them. The caret keeps its
    /// place in the text; a selection becomes the lines.
    public static func toggleComment(_ text: String, selection: NSRange, style: CommentStyle) -> LineEdit? {
        let s = text as NSString
        let lines = lines(of: selection, in: s)
        var body = s.substring(with: lines)
        let ending = body.hasSuffix("\n") ? "\n" : ""
        if !ending.isEmpty { body.removeLast() }
        var parts = body.components(separatedBy: "\n")
        let filled = parts.indices.filter { !parts[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = filled.first, let last = filled.last else { return nil }
        func lead(_ line: String) -> Int { (line.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count }
        func utf16(_ t: String) -> Int { (t as NSString).length }
        // Where each changed line changed before its text: (column, how much), for the caret.
        var shifts: [Int: (column: Int, delta: Int)] = [:]
        func edit(_ i: Int, at column: Int, remove: Int, insert: String) {
            let line = parts[i] as NSString
            parts[i] = line.replacingCharacters(in: NSRange(location: column, length: remove), with: insert)
            shifts[i] = (column, utf16(insert) - remove)
        }
        switch style {
        case .line(let mark):
            if filled.allSatisfy({ parts[$0].trimmingCharacters(in: .whitespaces).hasPrefix(mark) }) {
                for i in filled {
                    let at = lead(parts[i]), after = (parts[i] as NSString).substring(from: at + utf16(mark))
                    edit(i, at: at, remove: utf16(mark) + (after.hasPrefix(" ") ? 1 : 0), insert: "")
                }
            } else {
                let column = filled.map { lead(parts[$0]) }.min() ?? 0
                for i in filled { edit(i, at: column, remove: 0, insert: mark + " ") }
            }
        case .block(let open, let close):
            let a = parts[first].trimmingCharacters(in: .whitespaces), b = parts[last].trimmingCharacters(in: .whitespaces)
            if a.hasPrefix(open), b.hasSuffix(close) {
                var tail = parts[last]
                while tail.hasSuffix(" ") { tail.removeLast() }
                tail = String(tail.dropLast(close.count))
                while tail.hasSuffix(" ") { tail.removeLast() }
                parts[last] = tail
                let at = lead(parts[first]), after = (parts[first] as NSString).substring(from: at + utf16(open))
                edit(first, at: at, remove: utf16(open) + (after.hasPrefix(" ") ? 1 : 0), insert: "")
            } else {
                parts[last] += " " + close
                edit(first, at: lead(parts[first]), remove: 0, insert: open + " ")
            }
        }
        let out = parts.joined(separator: "\n") + ending
        guard selection.length == 0 else {
            return LineEdit(range: lines, replacement: out, selection: NSRange(location: lines.location, length: utf16(out) - utf16(ending)))
        }
        // The caret: on its line, moved by what changed before it.
        let old = body.components(separatedBy: "\n")
        var offset = selection.location - lines.location, index = 0
        while index < old.count - 1, offset > utf16(old[index]) { offset -= utf16(old[index]) + 1; index += 1 }
        var column = offset
        if let shift = shifts[index], column >= shift.column { column = max(shift.column, column + shift.delta) }
        let before = parts[..<index].reduce(0) { $0 + utf16($1) + 1 }
        return LineEdit(range: lines, replacement: out, selection: NSRange(location: lines.location + before + min(column, utf16(parts[index])), length: 0))
    }

    /// The start of line `number` (1-based), or of the last line past the end (Go to Line, ⌃G).
    public static func start(ofLine number: Int, in text: String) -> Int {
        let s = text as NSString
        var location = 0
        for _ in 1..<max(1, number) {
            guard let next = s.range(of: "\n", range: NSRange(location: location, length: s.length - location)).location as Int?,
                  next != NSNotFound else { break }
            location = next + 1
        }
        return location
    }
}
