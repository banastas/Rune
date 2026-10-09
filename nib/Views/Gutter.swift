// Line numbers (PRD ED6): a ruler down the text's left side in the scheme's gutter colors, one
// number for each line of the file, level with its first row when it wraps, the caret's in the
// text color. The numbers come from the editor's line index (a binary search), never counted
// from the top. It has no client view and the text view's own ruler support is off: nothing
// here touches `layoutManager`, which would switch the text view to TextKit 1. Beside the numbers,
// changes since the last commit (ED12): a column of square cells, as the HUD's cells, for a line
// added or changed, and a two-cell notch where lines were deleted.

import AppKit
import NibText

final class LineNumberRuler: NSRulerView {
    private weak var editor: Editor?
    private var digits = 0
    #if DEBUG
    /// The numbers drawn last, and the bright one, for the `gutter` scenario.
    private(set) var drawn: [Int] = []
    private(set) var drawnCurrent: Int?
    /// The change marks drawn last (0-based lines; "deleted" for a notch before the line), for `gitmarks`.
    private(set) var drawnMarks: [Int: String] = [:]
    #endif

    init(scrollView: NSScrollView, editor: Editor) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        clipsToBounds = true
        fit()
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    /// Not for VoiceOver: the strip says the line and column, and a conflict block is said as the
    /// caret comes into it, ✕ and all (it was an unlabelled ruler: the QA review's F82).
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    /// Wide enough for the longest number, and at least three digits, so it doesn't jump while
    /// a file grows past 99 lines.
    func fit() {
        let count = max(3, String(editor?.lineIndex.lineCount ?? 1).count)
        let width = ("8" as NSString).size(withAttributes: [.font: Scheme.font]).width
        let thickness = ceil(CGFloat(count) * width + 18)   // room for the change marks (ED12) after the numbers
        guard count != digits || ruleThickness != thickness else { return }
        digits = count
        ruleThickness = thickness
    }

    override func draw(_ dirtyRect: NSRect) {
        // Only the gutter: views don't clip to their bounds by default (macOS 14), and the
        // scroll view lays the ruler over the text's clip view, whose drawing this would cover.
        let dirtyRect = dirtyRect.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }
        Scheme.gutter.setFill()
        dirtyRect.fill()
        guard let editor, case let view = editor.textView, let layout = view.textLayoutManager,
              let content = layout.textContentManager else { return }
        let index = editor.lineIndex
        let origin = view.textContainerOrigin
        let caretLine = index.line(at: view.selectedRange().location)
        // With several carets, each one's line in view bright too (ED8).
        var caretLines: Set<Int> = [caretLine]
        if let carets = view.carets, carets.count > 1 {
            let span = view.viewportSpan()
            for caret in carets.all where span.contains(caret.head) { caretLines.insert(index.line(at: caret.head)) }
        }
        let font = Scheme.font
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Scheme.gutterForeground]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Scheme.gutterForegroundHighlight]
        // The part of the text beside what needs drawing.
        let top = convert(dirtyRect.origin, to: view).y, bottom = convert(NSPoint(x: 0, y: dirtyRect.maxY), to: view).y

        #if DEBUG
        drawn = []
        drawnCurrent = nil
        drawnMarks = [:]
        #endif
        let changes = editor.gitChanges
        let cell: CGFloat = 4, column = bounds.width - cell - 2   // 4 points clear of the numbers
        /// A notch: two cells across the boundary between lines, where committed lines were deleted.
        func notch(at y: CGFloat, before line: Int) {
            #if DEBUG
            drawnMarks[line] = "deleted"
            #endif
            Scheme.lineDiffDeleted.setFill()
            NSRect(x: column - cell - 1, y: y - cell / 2, width: cell, height: cell).fill()
            NSRect(x: column, y: y - cell / 2, width: cell, height: cell).fill()
        }
        /// The marks beside a line (1-based) whose rows span `top` to `top + height` in the text view.
        func mark(_ line: Int, top: CGFloat, height: CGFloat) {
            guard !changes.isEmpty else { return }
            let y = convert(NSPoint(x: 0, y: top), from: view).y
            if let kind = changes.lines[line - 1] {
                #if DEBUG
                drawnMarks[line - 1] = kind == .added ? "added" : "modified"
                #endif
                (kind == .added ? Scheme.lineDiffAdded : Scheme.lineDiffModified).setFill()
                var cellTop = y + 1
                while cellTop + cell <= y + height - 1 {
                    NSRect(x: column, y: cellTop, width: cell, height: cell).fill()
                    cellTop += cell + 1
                }
            }
            if changes.deletedBefore.contains(line - 1) { notch(at: y, before: line - 1) }
        }
        func number(_ line: Int, baseline: CGFloat) {
            #if DEBUG
            drawn.append(line)
            if line == caretLine { drawnCurrent = line }
            #endif
            let text = NSAttributedString(string: String(line), attributes: caretLines.contains(line) ? current : plain)
            let y = convert(NSPoint(x: 0, y: baseline), from: view).y - font.ascender
            text.draw(at: NSPoint(x: bounds.width - 10 - text.size().width, y: y))
        }

        let documentStart = content.documentRange.location
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top - origin.y))) ?? layout.textLayoutFragment(for: documentStart) else {
            number(1, baseline: origin.y + font.ascender)   // no text at all: line 1
            return
        }
        var last: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard origin.y + frame.minY <= bottom else { return false }
            last = fragment
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let row = fragment.textLineFragments.first
            let line = index.line(at: offset)
            number(line, baseline: origin.y + frame.minY + (row.map { $0.typographicBounds.minY + $0.glyphOrigin.y } ?? font.ascender))
            mark(line, top: origin.y + frame.minY, height: frame.height)
            return true
        }
        // Lines deleted at the very end: the notch under the last line.
        let length = (view.string as NSString).length
        let endsWithNewline = length > 0 && (view.string as NSString).character(at: length - 1) == 0x0A
        let end = index.lineCount - (endsWithNewline ? 1 : 0)
        if changes.deletedBefore.contains(end), let last, content.offset(from: documentStart, to: last.rangeInElement.endLocation) >= length {
            // Under the last line of text: above the empty row a final newline makes, when TextKit 2
            // lays that out as the paragraph's extra row (it was drawn under that row).
            let frame = last.layoutFragmentFrame
            var y = origin.y + frame.maxY
            if endsWithNewline, last.textLineFragments.count > 1, let extra = last.textLineFragments.last, extra.characterRange.length == 0 {
                y = origin.y + frame.minY + extra.typographicBounds.minY
            }
            notch(at: convert(NSPoint(x: 0, y: y), from: view).y, before: end)
        }
        // The empty line after a final newline: TextKit 2 lays it out as the last paragraph's
        // extra row, or below it.
        guard endsWithNewline,
              let end = last, content.offset(from: documentStart, to: end.rangeInElement.endLocation) >= length else { return }
        let frame = end.layoutFragmentFrame
        if end.textLineFragments.count > 1, let extra = end.textLineFragments.last, extra.characterRange.length == 0 {
            number(index.lineCount, baseline: origin.y + frame.minY + extra.typographicBounds.minY + extra.glyphOrigin.y)
        } else {
            number(index.lineCount, baseline: origin.y + frame.maxY + font.ascender)
        }
    }
}
