// A document's highlighting (PRD HL1, §6.3, §6.5): its syntax tree kept across edits, and
// its styles worked out a stretch at a time, the stretch on screen with a margin. The first
// parse of a big file is the only whole one (2.4 MB of Markdown: about half a second); after
// that, each change is found by comparing the new text with the last (common start and end),
// handed to tree-sitter as an edit, and only what it touched is parsed again. Queries,
// embedded languages and styles then cover just the stretch asked for.

import Foundation
import NibText
import SwiftTreeSitter

public actor SyntaxDocument {
    public let language: SyntaxLanguage
    public let root: String
    private let parser = Parser()
    private var tree: MutableTree?
    /// The text as last parsed, and its UTF-16 units (tree-sitter reads UTF-16).
    private var text = ""
    private var units: [UInt16] = []
    private var styles: Highlighter.StyleCache?

    public enum Parse: Sendable, Equatable {
        case unchanged
        /// Reparsed from the last tree: the change, in UTF-16 units of the new text.
        case incremental(NSRange)
        case whole
    }

    public init(language: SyntaxLanguage, root: String) {
        self.language = language
        self.root = root
        try? parser.setLanguage(language.tsLanguage)
    }

    /// Brings the tree up to `newText`.
    @discardableResult
    public func update(_ newText: String) -> Parse {
        let new = Self.units(of: newText)
        guard let old = tree else {
            tree = parser.parse(newText)
            text = newText
            units = new
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
        let (startPoint, _) = Self.point(at: start, in: units, from: (0, 0, 0))
        let (oldEndPoint, _) = Self.point(at: oldEnd, in: units, from: (start, Int(startPoint.row), Self.lineStart(before: start, in: units)))
        let (newEndPoint, _) = Self.point(at: newEnd, in: new, from: (start, Int(startPoint.row), Self.lineStart(before: start, in: units)))
        old.edit(InputEdit(startByte: start * 2, oldEndByte: oldEnd * 2, newEndByte: newEnd * 2,
                           startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: newEndPoint))
        // Read straight from the UTF-16 units (swift-tree-sitter's String reader turns each
        // chunk's offset into a String index). An edit still reads a few MB of a big file:
        // 30-110 ms at 2.4-5 MB, tree-sitter's own cost, off the main thread.
        tree = parser.parse(tree: old, readBlock: { byte, _ in
            let from = byte / 2
            guard from < new.count else { return nil }
            return new[from..<min(new.count, from + 4_096)].withUnsafeBytes { Data($0) }
        }) ?? parser.parse(newText)
        text = newText
        units = new
        return .incremental(NSRange(location: start, length: newEnd - start))
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

    /// Every character's scopes in `window`, as runs covering it.
    public func runs(in window: NSRange) -> [ScopeRun] {
        guard let tree else { return [] }
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let window = NSIntersectionRange(window, whole)
        var spans: [Highlighter.Span] = []
        Highlighter.collect(source, whole, language, roots: [root], window: window, tree: tree, string: text, into: &spans)
        return Highlighter.sweep(spans, window: window)
    }

    /// Each run's style in `window`, from the scheme; each scope stack's style is worked out
    /// once per scheme.
    public func styles(in window: NSRange, theme: Theme) -> [(range: NSRange, style: Style)] {
        if styles?.theme.id != theme.id { styles = Highlighter.StyleCache(theme: theme) }
        return runs(in: window).map { ($0.range, styles!.style(for: $0.scopes)) }
    }

    /// The tree as tree-sitter prints it, for tests: incremental and fresh parses must agree.
    public var treeDescription: String { tree?.rootNode?.sExpressionString ?? "" }
}
