// Several carets at once (PRD ED8), as Sublime has them: each a caret or a selection, kept in
// order, and two that meet or overlap become one. This is the arithmetic: what an edit at every
// caret does to the text, and where each caret goes; the text view draws them and turns keys
// and clicks into these. Offsets are UTF-16, as NSString's.

import Foundation

public struct Caret: Equatable, Sendable {
    /// Where a selection started (it stays put as the selection is extended), and where the caret is.
    public var anchor: Int
    public var head: Int
    /// The x that a run of ↑ and ↓ keeps to, past shorter lines (the text view sets it).
    public var goal: Double?

    public init(_ location: Int) {
        anchor = location
        head = location
    }

    public init(anchor: Int, head: Int, goal: Double? = nil) {
        self.anchor = anchor
        self.head = head
        self.goal = goal
    }

    /// A selection of `range`, the caret at its end.
    public init(range: NSRange) {
        anchor = range.location
        head = NSMaxRange(range)
    }

    public var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    public var isEmpty: Bool { anchor == head }
}

/// One replacement in the text as it is: `range`, made `replacement`.
public struct Edit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public struct Carets: Equatable, Sendable {
    /// In order, none overlapping, no two empty ones at one place.
    public private(set) var all: [Caret]
    /// The one the view follows, and the strip's line and column: the last one added.
    public private(set) var primary: Int

    /// Sorted and merged: ones that overlap become one, an empty caret at a selection's edge
    /// goes into it, and two empty carets at one place are one; two selections that only meet
    /// stay two, as in Sublime (⌘D on "aa" in "aaaa"). `primary` is an index into `carets` as
    /// given (the last one when nil), carried to where it's merged.
    public init(_ carets: [Caret], primary: Int? = nil) {
        precondition(!carets.isEmpty, "at least one caret")
        let chosen = primary ?? carets.count - 1
        let order = carets.indices.sorted { (carets[$0].range.location, carets[$0].range.length) < (carets[$1].range.location, carets[$1].range.length) }
        var merged: [Caret] = [], primaryAt = 0
        for index in order {
            let caret = carets[index]
            if let last = merged.last, Self.join(last, caret) {
                let start = min(last.range.location, caret.range.location)
                let end = max(NSMaxRange(last.range), NSMaxRange(caret.range))
                // The later caret's direction: a selection extended backward stays backward.
                let backward = caret.head < caret.anchor || (caret.isEmpty && last.head < last.anchor)
                merged[merged.count - 1] = backward ? Caret(anchor: end, head: start) : Caret(anchor: start, head: end)
            } else {
                merged.append(caret)
            }
            if index == chosen { primaryAt = merged.count - 1 }
        }
        all = merged
        self.primary = primaryAt
    }

    /// Two carets that are one (`a` starts first): overlapping, or meeting with one of them empty.
    private static func join(_ a: Caret, _ b: Caret) -> Bool {
        let ra = a.range, rb = b.range
        if rb.location < NSMaxRange(ra) { return true }
        return rb.location == NSMaxRange(ra) && (ra.length == 0 || rb.length == 0)
    }

    public var count: Int { all.count }
    public var primaryCaret: Caret { all[primary] }
    public var ranges: [NSRange] { all.map(\.range) }

    /// Each caret's range replaced: by one text each (`texts.count == count`), or by one for all.
    /// The edits, in the text as it is (in order), and the carets after: each just after its text.
    public func replacing(with texts: [String]) -> (edits: [Edit], after: Carets) {
        precondition(texts.count == 1 || texts.count == count, "one text, or one per caret")
        var edits: [Edit] = [], after: [Caret] = [], shift = 0
        for (index, caret) in all.enumerated() {
            let text = texts.count == 1 ? texts[0] : texts[index]
            let range = caret.range, length = (text as NSString).length
            edits.append(Edit(range: range, replacement: text))
            after.append(Caret(range.location + shift + length))
            shift += length - range.length
        }
        return (edits, Carets(after, primary: primary))
    }

    /// A deletion at each caret: a selection deletes itself; an empty caret, `span(head)`, the
    /// range to delete from it (the character before it, the word, back to the line's start), or
    /// nothing when it's nil (at the very start, say). Deletions that overlap become one.
    public func deleting(_ span: (Int) -> NSRange?) -> (edits: [Edit], after: Carets) {
        var ranges: [NSRange] = [], owners: [[Int]] = []
        for (index, caret) in all.enumerated() {
            guard let range = caret.isEmpty ? span(caret.head) : caret.range, range.length > 0 else {
                ranges.append(NSRange(location: caret.head, length: 0))
                owners.append([index])
                continue
            }
            if let last = ranges.last, range.location <= NSMaxRange(last), last.length > 0 {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
                owners[owners.count - 1].append(index)
            } else {
                ranges.append(range)
                owners.append([index])
            }
        }
        var edits: [Edit] = [], after: [Caret] = [], shift = 0, primaryAt = 0
        for (range, indices) in zip(ranges, owners) {
            if range.length > 0 { edits.append(Edit(range: range, replacement: "")) }
            if indices.contains(primary) { primaryAt = after.count }
            after.append(Caret(range.location + shift))
            shift -= range.length
        }
        return (edits, Carets(after, primary: primaryAt))
    }

    /// Each caret moved: `move` gives each its new self (a move collapses a selection; an extending
    /// one keeps its anchor). Carets that then meet become one.
    public func moving(_ move: (Caret) -> Caret) -> Carets {
        Carets(all.map(move), primary: primary)
    }

    /// One more caret, the primary now (⌘-click, ⌘D, Add Next Line).
    public func adding(_ caret: Caret) -> Carets {
        Carets(all + [caret], primary: all.count)
    }

    /// The primary caret made `caret` (a ⌘-drag growing the selection it began).
    public func replacingPrimary(with caret: Caret) -> Carets {
        var carets = all
        carets[primary] = caret
        return Carets(carets, primary: primary)
    }

    /// Without the caret at `location` (⌘-click on one): nil when it's the only one, or none is there.
    public func removing(at location: Int) -> Carets? {
        guard count > 1, let index = all.firstIndex(where: {
            $0.isEmpty ? $0.head == location : NSLocationInRange(location, $0.range) || NSMaxRange($0.range) == location
        }) else { return nil }
        var rest = all
        rest.remove(at: index)
        return Carets(rest, primary: index == primary ? rest.count - 1 : (primary > index ? primary - 1 : primary))
    }

    /// ⇧⌘L: each selection split at its lines, one selection a line, its line feed left out (a
    /// selection that ends at a line's start leaves that line out); an empty caret stays as it is.
    public func splitIntoLines(in text: NSString) -> Carets {
        var split: [Caret] = []
        for caret in all {
            let range = caret.range
            guard range.length > 0 else { split.append(caret); continue }
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                let line = text.lineRange(for: NSRange(location: location, length: 0))
                var part = min(NSMaxRange(line), end)
                if part == NSMaxRange(line), part > location, text.character(at: part - 1) == 0x0A { part -= 1 }
                split.append(Caret(anchor: location, head: part))
                location = NSMaxRange(line)
            }
        }
        return Carets(split)
    }
}

extension Carets {
    /// Which carets share a line command (ED8): ones on the same lines (Indent, Outdent, Toggle
    /// Comment, Duplicate Line), ones whose joins meet (Join Lines: a caret's line and the next,
    /// so a column of carets joins all its lines into one), or ones on the same or touching lines
    /// (Move Line: they move as a block).
    public enum LineGroups: Sendable { case sameLines, joins, block }

    /// A line command at every caret, all one change: `make` runs once for each group of carets
    /// in the text as it is (with a caret's own selection, or for a group its lines), and the
    /// carets after are where each command leaves them, a group's each in its own place. Nil
    /// when there's nothing to do (or, never expected, two groups' edits would overlap).
    public func lineEdits(in text: String, groups grouping: LineGroups = .sameLines, _ make: (NSRange) -> LineEdit?) -> (edits: [Edit], after: Carets)? {
        let ns = text as NSString
        func oneLine(_ range: NSRange) -> Bool {
            range.length <= 1 || ns.range(of: "\n", range: NSRange(location: range.location, length: range.length - 1)).location == NSNotFound
        }
        var groups: [(span: NSRange, members: [Int])] = []
        for (index, caret) in all.enumerated() {
            var span = LineEdits.lines(of: caret.range, in: ns)
            if grouping == .joins, oneLine(span), NSMaxRange(span) < ns.length {
                span = NSUnionRange(span, ns.lineRange(for: NSRange(location: NSMaxRange(span), length: 0)))
            }
            if let last = groups.last, span.location < NSMaxRange(last.span) || (grouping == .block && span.location == NSMaxRange(last.span)) {
                groups[groups.count - 1] = (NSUnionRange(last.span, span), last.members + [index])
            } else {
                groups.append((span, [index]))
            }
        }
        var edits: [Edit] = [], after: [Caret] = [], shift = 0, primaryAt = 0, previousEnd = 0
        for group in groups {
            let first = all[group.members[0]]
            let given = group.members.count == 1 ? first.range
                : oneLine(group.span) ? NSRange(location: first.range.location, length: 0) : group.span
            guard let edit = make(given) else {
                for member in group.members {
                    if member == primary { primaryAt = after.count }
                    after.append(Caret(anchor: all[member].anchor + shift, head: all[member].head + shift))
                }
                continue
            }
            guard edit.range.location >= previousEnd else { return nil }
            edits.append(Edit(range: edit.range, replacement: edit.replacement))
            previousEnd = NSMaxRange(edit.range)
            if group.members.count == 1 {
                // The command's own selection, as on one caret, still backward if it was.
                if group.members[0] == primary { primaryAt = after.count }
                let range = NSRange(location: edit.selection.location + shift, length: edit.selection.length)
                after.append(first.head < first.anchor && range.length > 0 ? Caret(anchor: NSMaxRange(range), head: range.location) : Caret(range: range))
            } else if !edit.shifts.isEmpty || edit.selection.length == given.length {
                // Each caret where its text went: by the shifts in its lines, or the lines' move.
                let moved = edit.selection.location - given.location
                for member in group.members {
                    if member == primary { primaryAt = after.count }
                    let caret = all[member]
                    after.append(edit.shifts.isEmpty
                        ? Caret(anchor: caret.anchor + moved + shift, head: caret.head + moved + shift)
                        : Caret(anchor: edit.map(caret.anchor) + shift, head: edit.map(caret.head) + shift))
                }
            } else {
                // Lines made one (Join Lines): one caret, where the command puts it.
                if group.members.contains(primary) { primaryAt = after.count }
                after.append(Caret(range: NSRange(location: edit.selection.location + shift, length: edit.selection.length)))
            }
            shift += (edit.replacement as NSString).length - edit.range.length
        }
        guard !edits.isEmpty else { return nil }
        return (edits, Carets(after, primary: primaryAt))
    }
}

/// What ⌘D and Select All Occurrences find (PRD ED8): words as Sublime takes them, and the same
/// text again, matched exactly (case and all), as a whole word when it came from one.
public enum Occurrences {
    /// Letters, digits and _.
    public static func isWord(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }   // a surrogate half: part of a letter outside the BMP
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
    }

    /// The word at `location`, or the one just before it (a caret at a word's end), or nil.
    public static func word(at location: Int, in text: NSString) -> NSRange? {
        var start = location, end = location
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// Whether `range` stands as a whole word: no word character either side of it.
    public static func isWhole(_ range: NSRange, in text: NSString) -> Bool {
        (range.location == 0 || !isWord(text.character(at: range.location - 1)))
            && (NSMaxRange(range) == text.length || !isWord(text.character(at: NSMaxRange(range))))
    }

    /// The first occurrence of `needle` at or after `location`, going round to the start once,
    /// that isn't in `taken`: nil when there's none left.
    public static func next(_ needle: String, in text: NSString, after location: Int, wholeWord: Bool, taken: [NSRange]) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        for (from, to) in [(location, text.length), (0, min(location + (needle as NSString).length, text.length))] {
            var search = NSRange(location: from, length: max(0, to - from))
            while search.length > 0 {
                let found = text.range(of: needle, options: [.literal], range: search)
                guard found.location != NSNotFound else { break }
                if (!wholeWord || isWhole(found, in: text)), !taken.contains(where: { NSIntersectionRange($0, found).length > 0 || $0 == found }) {
                    return found
                }
                search = NSRange(location: found.location + 1, length: NSMaxRange(search) - found.location - 1)
            }
        }
        return nil
    }

    /// Every occurrence, in order, none overlapping.
    public static func all(_ needle: String, in text: NSString, wholeWord: Bool) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var found: [NSRange] = [], search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let match = text.range(of: needle, options: [.literal], range: search)
            guard match.location != NSNotFound else { break }
            if !wholeWord || isWhole(match, in: text) { found.append(match) }
            let next = wholeWord && !isWhole(match, in: text) ? match.location + 1 : NSMaxRange(match)
            search = NSRange(location: next, length: text.length - next)
        }
        return found
    }
}
