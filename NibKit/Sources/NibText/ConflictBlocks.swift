// Conflict blocks in the text (PRD §4.7, §5.4): the marker lines Keep Both and the merge
// write (and git writes), found again in the buffer, and one block resolved: the first
// side, the second, or both. Offsets are UTF-16, as the text view counts them.

import Foundation

public struct ConflictBlock: Sendable, Equatable {
    public enum Choice: Sendable, Equatable { case first, second, both }

    /// The whole block: from the start of its `<<<<<<<` line to the end of its `>>>>>>>`
    /// line, with that line's break if it has one.
    public var range: NSRange
    /// Each side's text: whole lines, with their breaks.
    public var first: NSRange
    public var second: NSRange
    /// "Air · 10:42": what follows the markers.
    public var firstLabel: String
    public var secondLabel: String
    /// The marker lines (and a git base section, `|||||||` to `=======`), drawn apart from the text.
    public var markers: [NSRange]
}

extension ConflictText {
    /// The complete blocks in `text`, in order. A start marker with no end is left alone.
    public static func blocks(in text: String) -> [ConflictBlock] {
        let s = text as NSString
        guard s.range(of: "<<<<<<<").location != NSNotFound else { return [] }
        var result: [ConflictBlock] = []
        enum Part { case none, first, base, second }
        var part = Part.none
        var start = 0, firstStart = 0, firstEnd = 0, secondStart = 0
        var firstLabel = "", markers: [NSRange] = [], baseStart = 0
        var location = 0
        while location < s.length {
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            s.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let line = s.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let whole = NSRange(location: lineStart, length: lineEnd - lineStart)
            if let label = marker("<", line) {
                // A start (again, if an earlier one never ended: that one is left as text).
                part = .first; start = lineStart; firstStart = lineEnd; firstLabel = label; markers = [whole]
            } else if part == .first, marker("|", line) != nil {
                part = .base; firstEnd = lineStart; baseStart = lineStart
            } else if part != .none, part != .second, line == "=======" {
                if part == .first { firstEnd = lineStart; markers.append(whole) }
                else { markers.append(NSRange(location: baseStart, length: lineEnd - baseStart)) }
                part = .second; secondStart = lineEnd
            } else if part == .second, let label = marker(">", line) {
                markers.append(whole)
                result.append(ConflictBlock(range: NSRange(location: start, length: lineEnd - start),
                                            first: NSRange(location: firstStart, length: firstEnd - firstStart),
                                            second: NSRange(location: secondStart, length: lineStart - secondStart),
                                            firstLabel: firstLabel, secondLabel: label, markers: markers))
                part = .none
            }
            location = lineEnd
        }
        return result
    }

    /// What replaces `block` for `choice`: that side's lines, or both, first side first.
    public static func resolution(of block: ConflictBlock, _ choice: ConflictBlock.Choice, in text: String) -> String {
        let s = text as NSString
        let first = s.substring(with: block.first), second = s.substring(with: block.second)
        var kept: String
        switch choice {
        case .first: kept = first
        case .second: kept = second
        case .both: kept = first.isEmpty || first.hasSuffix("\n") ? first + second : first + "\n" + second
        }
        // A block on the file's last line, with no break after it: the result has none either.
        let endsWithBreak = block.range.length > 0 && s.character(at: NSMaxRange(block.range) - 1) == 0x0A
        if !endsWithBreak, kept.hasSuffix("\n") { kept.removeLast() }
        return kept
    }

    /// The label after a seven-character marker of `c` ("<<<<<<< Air · 10:42" → "Air · 10:42"), or nil.
    static func marker(_ c: Character, _ line: String) -> String? {
        let head = String(repeating: c, count: 7)
        guard line.hasPrefix(head) else { return nil }
        let rest = line.dropFirst(7)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
