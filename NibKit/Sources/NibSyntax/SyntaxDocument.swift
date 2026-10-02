// A document's highlighting (PRD HL1, §6.3, §6.5): its syntax tree kept across edits, and
// its styles worked out a stretch at a time, the stretch on screen with a margin. A change is
// found by comparing the new text with the last (common start and end), handed to tree-sitter
// as an edit, and only what it touched is parsed again. Queries, embedded languages and styles
// then cover just the stretch asked for.
//
// A small text (up to 256K characters) keeps a tree of the whole. A big one keeps a tree of the
// stretch around the view only: a whole tree costs 4-58 bytes a character (Markdown with blank
// lines 11, without 58; JavaScript 13), so a 2.4 MB scratch file's was 26-130 MB (§6.5: idle
// memory with it ≤ 100 MB). The stretch is parsed from a place where a parse of the whole is in
// its starting state too, so it reads on exactly as that parse does: in Markdown, a block in the
// document or a section at the start of a line, or an item of such a list; a statement at the
// top of a script; a rule at the top of a style sheet. Those places are found by parsing the
// text a stretch at a time (and letting each tree go), only as far as the view needs, and kept,
// moved along by edits. Past an edit, they hold only if the parse after it falls back in step
// with the one they came from (the same places in a stretch at its end): typing ``` turns the
// rest of a file into code, typing a word doesn't. Until that's known they're unsure, and looked
// at again when the view goes there.

import Foundation
import NibText
import SwiftTreeSitter

public actor SyntaxDocument {
    public let language: SyntaxLanguage
    public let root: String
    let limits: Limits
    private let parser = Parser()
    private var started = false
    /// The text as last brought in, and its UTF-16 units (tree-sitter reads UTF-16).
    private var text = ""
    private var units: [UInt16] = []
    /// The tree: of the whole text when it's small, of a stretch around the view when it's big.
    private var slice: Slice?
    /// Where a parse can start (ascending, always 0 first). They're good before the first of
    /// `unsure`; past it they're where they were before an edit whose reach isn't known yet,
    /// or haven't been looked for yet.
    private(set) var checkpoints: [Int] = [0]
    private(set) var unsure: [Int] = [0]
    private var styles: Highlighter.StyleCache?

    struct Limits: Sendable {
        /// Texts up to this long (UTF-16 units) keep a tree of the whole.
        var whole = 262_144
        /// A big text is parsed this much at a time to find places to start.
        var chunk = 131_072
        /// How far a stretch reaches before and after the window asked for.
        var lead = 32_768
        var trail = 65_536
        /// The end of a parse that isn't trusted (what's there may be cut short), and the least
        /// a stretch keeps past the window.
        var margin = 4_096
    }

    private struct Slice {
        var range: NSRange
        var tree: MutableTree
        /// The text it was parsed from, for the queries: its own, and its closer if it's cut short.
        var string: String
        /// It runs to the end of the text, and grows with it (typing at the end of a scratch file).
        var toEnd: Bool
        /// A small text's tree of the whole.
        var whole = false
        /// An edit before it may have changed how its start reads: looked at before it's used.
        var unchecked = false
    }

    public enum Parse: Sendable, Equatable {
        case unchanged
        /// Reparsed from the last tree: the change, in UTF-16 units of the new text.
        case incremental(NSRange)
        case whole
    }

    public init(language: SyntaxLanguage, root: String) {
        self.init(language: language, root: root, limits: Limits())
    }

    init(language: SyntaxLanguage, root: String, limits: Limits) {
        self.language = language
        self.root = root
        self.limits = language.hasStarts ? limits : Limits(whole: .max)
        try? parser.setLanguage(language.tsLanguage)
    }

    /// Brings the tree up to `newText`. A big text's first parse waits for the first stretch asked for.
    @discardableResult
    public func update(_ newText: String) -> Parse {
        let new = Self.units(of: newText)
        guard started else {
            started = true
            text = newText
            units = new
            if new.count <= limits.whole { parseWhole() }
            return .whole
        }
        if new == units { return .unchanged }
        // The change: what's left between the common start and the common end.
        let limit = min(units.count, new.count)
        var start = 0
        while start < limit, units[start] == new[start] { start += 1 }
        var tail = 0
        while tail < limit - start, units[units.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }
        let oldEnd = units.count - tail, newEnd = new.count - tail
        let change = Parse.incremental(NSRange(location: start, length: newEnd - start))
        // A place to start on the changed line may not be one now (deleting the space of "- item").
        let lineStart = max(Self.lineStart(before: start, in: units), start - 256)
        move(dropping: lineStart, start: start, oldEnd: oldEnd, delta: newEnd - oldEnd)
        let old = units
        text = newText
        units = new
        guard var current = slice else { markUnsure(start); return change }
        slice = nil
        let from = current.range.location, end = NSMaxRange(current.range)
        if from == 0 || lineStart > from, oldEnd <= end || current.toEnd {
            // In the stretch: its tree edited, in its own terms, and parsed again where it changed.
            let to = current.toEnd ? new.count : end + newEnd - oldEnd
            let (startPoint, _) = Self.point(at: start, in: old, from: (from, 0, from))
            let rowStart = max(from, Self.lineStart(before: start, in: old))
            let (oldEndPoint, _) = Self.point(at: oldEnd, in: old, from: (start, Int(startPoint.row), rowStart))
            let (newEndPoint, _) = Self.point(at: newEnd, in: new, from: (start, Int(startPoint.row), rowStart))
            current.tree.edit(InputEdit(startByte: (start - from) * 2, oldEndByte: (oldEnd - from) * 2, newEndByte: (newEnd - from) * 2,
                                        startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint))
            // Read straight from the UTF-16 units (swift-tree-sitter's String reader turns each
            // chunk's offset into a String index).
            guard let tree = parse(from: from, to: to, cut: !current.toEnd, after: current.tree) ?? parse(from: from, to: to, cut: !current.toEnd)
            else { markUnsure(start); return change }
            current.tree = tree
            current.range = NSRange(location: from, length: to - from)
            current.string = current.whole ? newText : string(from: from, to: to, cut: !current.toEnd)
            slice = current
            if !current.whole { absorb(tree, from: from, to: to, cut: !current.toEnd, changedAfter: newEnd) }
        } else if oldEnd <= from {
            // Before it: its text is the same, but how its start reads may not be.
            current.range.location += newEnd - oldEnd
            current.unchecked = true
            slice = current
            markUnsure(start)
        } else if start >= end, !current.toEnd {
            slice = current   // after it: untouched
            markUnsure(start)
        } else {
            markUnsure(start)   // across its start or its end: let go
        }
        return change
    }

    /// The text's UTF-16 units in one copy (walking `utf16` on a bridged string goes a
    /// character at a time).
    static func units(of text: String) -> [UInt16] {
        let ns = text as NSString
        return [UInt16](unsafeUninitializedCapacity: ns.length) { buffer, count in
            if let base = buffer.baseAddress { ns.getCharacters(base, range: NSRange(location: 0, length: ns.length)) }
            count = ns.length
        }
    }

    /// A position as tree-sitter counts it: the row, and the column in bytes (UTF-16: two a
    /// unit), counted on from a known one (offset, row, where that row starts).
    static func point(at offset: Int, in units: [UInt16], from known: (offset: Int, row: Int, lineStart: Int)) -> (Point, Int) {
        var row = known.row, lineStart = known.lineStart, i = known.offset
        while i < offset {
            if units[i] == 0x0A { row += 1; lineStart = i + 1 }
            i += 1
        }
        return (Point(row: row, column: (offset - lineStart) * 2), lineStart)
    }

    static func lineStart(before offset: Int, in units: [UInt16]) -> Int {
        var i = offset
        while i > 0, units[i - 1] != 0x0A { i -= 1 }
        return i
    }

    // MARK: Stretches

    /// The units from `from` to `to`, parsed: afresh, or from `old` (edited to match) where it can.
    /// Read straight from the units, 4K at a time. `cut`: it stops short of the text's end, and is
    /// read with `closer` after it.
    private func parse(from: Int, to: Int, cut: Bool, after old: MutableTree? = nil) -> MutableTree? {
        let units = self.units, closer = cut ? language.closer : []
        return parser.parse(tree: old, readBlock: { byte, _ in
            let at = from + byte / 2
            if at < to { return units[at..<min(to, at + 4_096)].withUnsafeBytes { Data($0) } }
            guard at - to < closer.count else { return nil }
            return closer[(at - to)...].withUnsafeBytes { Data($0) }
        })
    }

    private func string(from: Int, to: Int, cut: Bool) -> String {
        String(decoding: units[from..<to] + (cut ? language.closer : []), as: UTF16.self)
    }

    /// A small text: one tree of the whole.
    private func parseWhole() {
        checkpoints = [0]
        unsure = [0]
        guard let tree = parse(from: 0, to: units.count, cut: false) else { slice = nil; return }
        slice = Slice(range: NSRange(location: 0, length: units.count), tree: tree, string: text, toEnd: true, whole: true)
    }

    /// Makes sure the tree covers `window`: the stretch there is, or a new one.
    private func ensureSlice(covering window: NSRange) {
        let length = units.count
        func covers(_ slice: Slice) -> Bool {
            window.location >= slice.range.location && (slice.toEnd || NSMaxRange(window) + limits.margin <= NSMaxRange(slice.range))
        }
        if let current = slice, current.unchecked {
            // An edit came before it: if its start is still a good place, it stays.
            verify(through: current.range.location)
            if isGood(current.range.location) { slice?.unchecked = false }
        }
        if let current = slice, !current.unchecked, covers(current) {
            // A whole text that's grown big gives its places to start, and is cut down to a stretch.
            guard current.whole, length > limits.whole else { return }
            absorb(current.tree, from: 0, to: length, cut: false, changedAfter: 0)
        }
        slice = nil   // the old tree goes before a new one is made
        if length <= limits.whole { parseWhole(); return }
        let target = max(0, window.location - limits.lead)
        var to = min(length, NSMaxRange(window) + limits.trail)
        // Known good places past its end too, so it can end on one: at the start of a block,
        // with nothing cut short (a fence's code read to its end, as in a parse of the whole),
        // unless the block runs on more than a chunk.
        verify(through: to)
        let from = checkpoints[index(after: target) - 1]
        let next = index(after: to - 1)
        if next < checkpoints.count, checkpoints[next] - to <= limits.chunk, checkpoints[next] < unsure.first ?? .max { to = checkpoints[next] }
        else if next == checkpoints.count, length - to <= limits.chunk, unsure.isEmpty { to = length }
        if to < length, UTF16.isTrailSurrogate(units[to]) { to += 1 }   // not between the halves of a pair
        guard let tree = parse(from: from, to: to, cut: to < length) else { return }
        slice = Slice(range: NSRange(location: from, length: to - from), tree: tree, string: string(from: from, to: to, cut: to < length), toEnd: to == length)
        absorb(tree, from: from, to: to, cut: to < length, changedAfter: from)
    }

    /// Finds good places to start up to `target`: the text parsed a chunk at a time from the
    /// last good one, each tree let go once its places are taken.
    private func verify(through target: Int) {
        while let first = unsure.first, first <= target {
            let from = first == 0 ? 0 : checkpoints[index(after: first - 1) - 1]
            var size = limits.chunk
            while true {
                let to = min(units.count, from + size)
                guard let tree = parse(from: from, to: to, cut: to < units.count) else { unsure.removeAll(); return }
                let trusted = to == units.count ? to : to - limits.margin
                // One construct filling the chunk (a fence, a script): a bigger one, so it gets past it.
                if to == units.count || Self.starts(in: tree, at: from, language: language, big: limits.chunk).contains(where: { $0 > from && $0 < trusted }) {
                    absorb(tree, from: from, to: to, cut: to < units.count, changedAfter: from)
                    break
                }
                size *= 2
            }
        }
    }

    /// A parse of `from` to `to`, started at a place to start: its own places replace the ones
    /// there. Past its trusted end, the places there stay as good as they were if its last few
    /// are the ones there were (it's back in step with the parse they came from), and are unsure
    /// if not. `changedAfter`: where an edit in it ended (places before that were bound to move).
    private func absorb(_ tree: MutableTree, from: Int, to: Int, cut: Bool, changedAfter: Int) {
        let reachesEnd = to >= units.count && !cut
        let trusted = reachesEnd ? units.count : to - limits.margin
        guard trusted > from else { markUnsure(from + 1); return }
        let fresh = Self.starts(in: tree, at: from, language: language, big: limits.chunk).filter { $0 > from && $0 <= trusted }
        let lo = index(after: from), hi = index(after: trusted)
        let old = Array(checkpoints[lo..<hi])
        checkpoints.replaceSubrange(lo..<hi, with: fresh)
        // Unsure marks in it are settled by it (one at the very start too: nothing's unsure
        // before 0); the last of them is where the old places that run on past it came from.
        let settles = { (mark: Int) in mark > from || from == 0 }
        let breaks = unsure.filter { settles($0) && $0 <= trusted }
        unsure.removeAll { settles($0) && (reachesEnd || $0 <= trusted) }
        guard !reachesEnd else { return }
        let after = max(breaks.last ?? from, changedAfter)
        let freshTail = fresh.filter { $0 > after }.suffix(3), oldTail = old.filter { $0 > after }.suffix(3)
        if !(freshTail.count == 3 && freshTail.elementsEqual(oldTail)) { markUnsure(trusted) }
    }

    /// The places to start and the unsure marks, through an edit: those on the changed line
    /// (from `lineStart`) and in the change go, those after it move.
    private func move(dropping lineStart: Int, start: Int, oldEnd: Int, delta: Int) {
        let lo = index(after: lineStart - 1), hi = index(after: oldEnd)
        if delta != 0 { for i in hi..<checkpoints.count { checkpoints[i] += delta } }
        checkpoints.removeSubrange(lo..<hi)
        if checkpoints.first != 0 { checkpoints.insert(0, at: 0) }
        var moved: [Int] = []
        for mark in unsure {
            let at = mark < start ? mark : mark <= oldEnd ? start : mark + delta
            if moved.last != at { moved.append(at) }
        }
        unsure = moved
    }

    private func markUnsure(_ offset: Int) {
        var low = 0, high = unsure.count
        while low < high {
            let mid = (low + high) / 2
            if unsure[mid] < offset { low = mid + 1 } else { high = mid }
        }
        if low == unsure.count || unsure[low] != offset { unsure.insert(offset, at: low) }
    }

    /// The first checkpoint after `offset`.
    private func index(after offset: Int) -> Int {
        var low = 0, high = checkpoints.count
        while low < high {
            let mid = (low + high) / 2
            if checkpoints[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func isGood(_ offset: Int) -> Bool {
        let at = index(after: offset) - 1
        return at >= 0 && checkpoints[at] == offset && (offset == 0 || offset < unsure.first ?? .max)
    }

    /// Where parses can start in `tree` (parsed from `offset`), in order: places where a parse
    /// of the whole text is in its starting state too, so a parse from there reads on as it does.
    static func starts(in tree: MutableTree, at offset: Int, language: SyntaxLanguage, big: Int) -> [Int] {
        guard let root = tree.rootNode else { return [] }
        var found: [Int] = []
        func walk(_ node: Node, _ type: String) {
            node.enumerateChildren { child in
                guard child.isNamed, let kind = child.nodeType else { return }
                if language.canStart(at: kind, in: type, column: Int(child.pointRange.lowerBound.column)) {
                    let at = offset + child.range.location
                    if found.last != at { found.append(at) }   // a section starts where its heading does
                }
                if language.holdsStarts(kind, in: type, length: child.range.length, big: big) { walk(child, kind) }
            }
        }
        walk(root, root.nodeType ?? "")
        return found
    }

    // MARK: Styles

    /// Every character's scopes in `window`, as runs covering it.
    public func runs(in window: NSRange) -> [ScopeRun] {
        guard started else { return [] }
        let window = NSIntersectionRange(window, NSRange(location: 0, length: units.count))
        ensureSlice(covering: window)
        guard let slice else { return [] }
        // The root scope spans the whole text, as in a parse of the whole: the longest span, so
        // the outermost (a fence cut off by a stretch's end runs on into its closer, past it).
        var spans = [Highlighter.Span(range: NSRange(location: 0, length: units.count), scope: root, order: (0, -1, 0))]
        Highlighter.collect(text as NSString, slice.range, language, roots: [], window: window, tree: slice.tree, string: slice.string, into: &spans)
        return Highlighter.sweep(spans, window: window)
    }

    /// Each run's style in `window`, from the scheme; each scope stack's style is worked out
    /// once per scheme.
    public func styles(in window: NSRange, theme: Theme) -> [(range: NSRange, style: Style)] {
        if styles?.theme.id != theme.id { styles = Highlighter.StyleCache(theme: theme) }
        return runs(in: window).map { ($0.range, styles!.style(for: $0.scopes)) }
    }

    /// Sublime's match_tags (PRD ED10): in HTML and XML, the innermost element round `offset`,
    /// its start tag's name and its end tag's, from the tree. None outside an element, or for one
    /// without an end tag (a void element, one left open, XML's `<empty/>`).
    public func enclosingTagNames(at offset: Int) -> [NSRange] {
        guard language == .html || language == .xml, let slice, let root = slice.tree.rootNode else { return [] }
        // HTML's start_tag, end_tag and tag_name; XML's STag, ETag and Name.
        let (start, end, name) = language == .xml ? ("STag", "ETag", "Name") : ("start_tag", "end_tag", "tag_name")
        let local = offset - slice.range.location
        guard local >= 0, local <= slice.range.length else { return [] }
        let at = UInt32(local * 2)   // the tree counts bytes of UTF-16
        var node = root.descendant(in: at..<at)
        while let current = node {
            if let kind = current.nodeType, kind == "element" || kind == "script_element" || kind == "style_element" {
                var names: [NSRange] = []
                current.enumerateChildren { child in
                    guard child.nodeType == start || child.nodeType == end else { return }
                    child.enumerateChildren { part in
                        if part.nodeType == name { names.append(NSRange(location: part.range.location + slice.range.location, length: part.range.length)) }
                    }
                }
                if names.count == 2 { return names }
            }
            node = current.parent
        }
        return []
    }

    /// The tree as tree-sitter prints it, for tests: incremental and fresh parses must agree.
    public var treeDescription: String { slice?.tree.rootNode?.sExpressionString ?? "" }

    /// The stretch the tree covers, for tests.
    var sliceRange: NSRange? { slice?.range }
}

extension SyntaxLanguage {
    /// Whether a big text in this language can be parsed a stretch at a time. Not JSON (inside an
    /// object, a key reads as a string), HTML (inside an element, its end tag reads as a stray one)
    /// or shell scripts (tree-sitter-bash carries state from one command to the next: a parse
    /// started at one took the line after a pipeline for more of it, the windowed tests of
    /// 2026-09-30): a tree of the whole for those, at any size.
    var hasStarts: Bool { self == .markdown || self == .javascript || self == .css }

    /// What a stretch that stops short of the text's end is read with after it: the end of what
    /// tree-sitter reads only once it sees the end, so one the stretch's end cuts off reads up to
    /// there as in a parse of the whole. A block comment, and in JavaScript a template string:
    /// without it, tree-sitter read a /* with no */ as code and a ` with no end as one stray
    /// character, and found places to start inside them (the stress tests of 2026-09-30); in
    /// Markdown, front matter (--- or +++ at the very top, to the next such line). After anything
    /// else it's a stray character or line at the very end, past what's trusted. Markdown's
    /// fences and HTML blocks run to the end anyway.
    var closer: [UInt16] {
        switch self {
        case .javascript: Array("\n*/`".utf16)
        case .css: Array("\n*/".utf16)
        case .markdown: Array("\n---\n+++\n".utf16)
        default: []
        }
    }

    /// Whether a parse that starts at a `kind` node in a `parent` node is in the state a parse of
    /// the whole text is in there (§6.3): a Markdown block in the document or a section, at the
    /// start of a line, or an item of such a list; a statement at the top of a script; a rule at
    /// the top of a style sheet. Not inside a function or a rule: what follows its end would
    /// read differently. Never where the parse of the whole was lost (an ERROR).
    func canStart(at kind: String, in parent: String, column: Int) -> Bool {
        guard kind != "ERROR" else { return false }
        switch self {
        case .markdown: return column == 0 && (parent == "document" || parent == "section" || (parent == "list" && kind == "list_item"))
        case .javascript: return parent == "program"
        case .css: return parent == "stylesheet"
        default: return false
        }
    }

    /// Whether to look inside a node for places to start: Markdown's sections, and a long list
    /// (a whole scratch file can be one).
    func holdsStarts(_ kind: String, in parent: String, length: Int, big: Int) -> Bool {
        self == .markdown && (kind == "section" || (kind == "list" && (parent == "document" || parent == "section") && length > big))
    }
}
