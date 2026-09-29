// Tidying on ⌘S (PRD ED6): trailing spaces and tabs off every line, and a final newline if
// the file has none, as settings, applied only when the user saves with ⌘S (Nib's own saves,
// a second after typing stops, never change the text) and only to files they've edited. One
// change from the first place it touches to the last, with the selection carried through.

import Foundation

public enum SaveTidy {
    public struct Result: Sendable, Equatable {
        /// nil when there's nothing to tidy.
        public var edit: LineEdit?
        public var trimmedLines = 0
        public var addedNewline = false
    }

    public static func tidy(_ text: String, selection: NSRange, trimTrailing: Bool, finalNewline: Bool) -> Result {
        let s = text as NSString
        var cuts: [NSRange] = []   // trailing whitespace, in order
        if trimTrailing {
            var lineStart = 0
            while lineStart < s.length {
                var lineEnd = 0, contentsEnd = 0
                s.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
                var i = contentsEnd
                while i > lineStart, [0x20, 0x09].contains(s.character(at: i - 1)) { i -= 1 }
                if i < contentsEnd { cuts.append(NSRange(location: i, length: contentsEnd - i)) }
                lineStart = lineEnd
            }
        }
        // The end, once trimmed: a newline unless the text is empty or ends in one.
        let trimmedLength = s.length - cuts.reduce(0) { $0 + $1.length }
        let lastIsNewline = s.length > 0 && s.character(at: s.length - 1) == 0x0A
        let addNewline = finalNewline && trimmedLength > 0 && !lastIsNewline
        guard !cuts.isEmpty || addNewline else { return Result() }

        // One replacement, from the first cut (or the end) to the end of the last.
        let start = cuts.first?.location ?? s.length
        let end = cuts.last.map(NSMaxRange) ?? s.length
        var replacement = ""
        var at = start
        for cut in cuts {
            replacement += s.substring(with: NSRange(location: at, length: cut.location - at))
            at = NSMaxRange(cut)
        }
        replacement += s.substring(with: NSRange(location: at, length: end - at))
        if addNewline {
            replacement += s.substring(from: end) + "\n"
        }
        let range = NSRange(location: start, length: (addNewline ? s.length : end) - start)

        func moved(_ location: Int) -> Int {
            var shift = 0
            for cut in cuts {
                if location >= NSMaxRange(cut) { shift += cut.length }
                else if location > cut.location { shift += location - cut.location }   // inside a cut: to its start
            }
            return location - shift
        }
        let from = moved(selection.location), to = moved(NSMaxRange(selection))
        return Result(edit: LineEdit(range: range, replacement: replacement, selection: NSRange(location: from, length: to - from)),
                      trimmedLines: cuts.count, addedNewline: addNewline)
    }
}
