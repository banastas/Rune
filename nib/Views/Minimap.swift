// The minimap (PRD ED11; the user's call, 2026-10-02): the text beside the scroller at a
// seventh of its size, as Sublime shows it. Each word is a bar in its syntax color, lines wrap
// as the editor's do, conflict blocks are in the muted red, and a box lies over the lines in
// view. A click or a drag in it scrolls the text there.
// It draws only the rows it shows, from the text storage's own string (never a copy of it) and
// the editor's styles, which it asks to cover what it shows. A text taller than the minimap
// moves in it as the text scrolls, the box going from its top to its bottom (VS Code's way):
// the rows are the minimap's own, a row per `columns` characters of a line, so no layout of
// text out of view is needed. Nothing here touches `layoutManager`, which would switch the
// text view to TextKit 1.

import AppKit
import NibText

/// The editor's scroll view, with the minimap between the text and the scroller (or under the
/// scroller's right edge, with overlay scrollers).
final class EditorScrollView: NSScrollView {
    var minimap: MinimapView? {
        didSet {
            guard oldValue !== minimap else { return }
            oldValue?.removeFromSuperview()
            if let minimap { addSubview(minimap, positioned: .below, relativeTo: verticalScroller) }
            tile()
        }
    }

    override func tile() {
        super.tile()
        guard let minimap else { return }
        var clip = contentView.frame
        // A narrow window keeps its text: no minimap with less than 200 points of text beside it.
        minimap.isHidden = clip.width - MinimapView.width < 200
        guard !minimap.isHidden else { return }
        clip.size.width -= MinimapView.width
        contentView.frame = clip
        minimap.frame = NSRect(x: clip.maxX, y: clip.minY, width: MinimapView.width, height: clip.height)
    }
}

final class MinimapView: NSView {
    static let width: CGFloat = 100
    /// A seventh of the editor's size, about Sublime's.
    static let scale: CGFloat = 1.0 / 7

    private weak var editor: Editor?

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: .zero)
        setAccessibilityElement(false)   // a picture of the text; the scroller is the control
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: The model: rows, and where the box and the text stand

    /// The editor's text at the minimap's scale: a row's height, a character's width, and the
    /// characters in a row (the editor's own wrap width).
    private struct Metrics: Equatable {
        var row: CGFloat
        var character: CGFloat
        var columns: Int
        var tab: Int
    }

    private func metrics(_ editor: Editor) -> Metrics {
        let font = Scheme.font
        let character = ("8" as NSString).size(withAttributes: [.font: font]).width
        let line = ceil(font.ascender - font.descender + font.leading)
        let container = editor.textView.textContainer
        let wide = (container?.size.width ?? editor.textView.bounds.width) - 2 * (container?.lineFragmentPadding ?? 0)
        return Metrics(row: max(1.5, line * Self.scale), character: max(0.5, character * Self.scale),
                       columns: max(20, Int(wide / max(1, character))), tab: max(1, editor.indentation.width))
    }

    /// Each line's first row (and one past the last), a row per `columns` characters: worked
    /// out again only after an edit or a change of width.
    private var rowStarts: [Int] = [0, 1]
    private var modelColumns = 0
    private var modelStale = true

    private func rebuildRows(_ editor: Editor, columns: Int) {
        guard modelStale || columns != modelColumns else { return }
        let starts = editor.lineIndex.starts
        let length = editor.textView.textStorage?.length ?? 0
        var rows = [Int](repeating: 0, count: starts.count + 1)
        var total = 0
        for i in starts.indices {
            rows[i] = total
            let end = i + 1 < starts.count ? starts[i + 1] - 1 : length   // before its "\n"
            total += max(1, (end - starts[i] + columns - 1) / columns)
        }
        rows[starts.count] = total
        rowStarts = rows
        modelColumns = columns
        modelStale = false
    }

    /// The row the character at `offset` is on.
    private func row(of offset: Int, _ editor: Editor, _ columns: Int) -> Int {
        let line = editor.lineIndex.line(at: offset)
        let start = editor.lineIndex.start(ofLine: line) ?? 0
        return min(rowStarts[line - 1] + max(0, offset - start) / columns, rowStarts[line] - 1)
    }

    /// The line (0-based) a row is in: a binary search of `rowStarts`.
    private func line(ofRow row: Int) -> Int {
        var low = 0, high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= row { low = mid } else { high = mid - 1 }
        }
        return min(low, rowStarts.count - 2)
    }

    /// The first character of a row.
    private func offset(ofRow row: Int, _ editor: Editor, _ columns: Int) -> Int {
        let line = line(ofRow: row)
        let starts = editor.lineIndex.starts, length = editor.textView.textStorage?.length ?? 0
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return min(starts[line] + (row - rowStarts[line]) * columns, max(starts[line], end))
    }

    /// Where things stand, worked out for each draw and each move of the mouse.
    private struct Place {
        var metrics: Metrics
        var totalRows: Int
        var topRow: Int
        var visibleRows: Int
        /// How far down the text the minimap's top is, in points.
        var offset: CGFloat
        var box: NSRect
    }

    private func place() -> Place? {
        guard let editor else { return nil }
        let m = metrics(editor)
        rebuildRows(editor, columns: m.columns)
        // The first and last characters in view, asked inside the text (in the inset above it, the
        // answer was the end of the text).
        let view = editor.textView, visible = view.visibleRect, origin = view.textContainerOrigin
        let x = origin.x + 1, above = max(visible.minY, origin.y) + 1
        let first = view.characterIndexForInsertion(at: NSPoint(x: x, y: above))
        let last = view.characterIndexForInsertion(at: NSPoint(x: x, y: max(above, min(visible.maxY, view.bounds.height - origin.y) - 1)))
        let total = rowStarts.last ?? 1
        let top = first == NSNotFound ? 0 : row(of: first, editor, m.columns)
        let bottom = last == NSNotFound ? top : max(top, row(of: last, editor, m.columns))
        let shown = bottom - top + 1
        let content = CGFloat(total) * m.row, height = bounds.height
        var offset: CGFloat = 0
        if content > height {
            // The box goes from the top to the bottom as the text scrolls, and the text with it.
            offset = CGFloat(top) / CGFloat(max(1, total - shown)) * (content - height)
            offset = min(max(0, offset), content - height)
        }
        let box = NSRect(x: 0, y: CGFloat(top) * m.row - offset, width: bounds.width, height: max(m.row, CGFloat(shown) * m.row))
        return Place(metrics: m, totalRows: total, topRow: top, visibleRows: shown, offset: offset, box: box)
    }

    /// The characters it shows, from where the text is scrolled now: the editor styles them too
    /// (`Editor.styleWindow`). Worked out from the rows, not taken from the last draw, which a
    /// scroll leaves behind until the next one (the editor asked for the stretch from the top of
    /// a 2.4 MB file to its end, and took 5 s to color it: `bigfile`, 2026-10-02).
    func shownRange() -> NSRange? {
        guard let editor, let storage = editor.textView.textStorage, let place = place() else { return nil }
        let m = place.metrics
        let firstRow = max(0, Int(place.offset / m.row)), lastRow = min(place.totalRows - 1, Int((place.offset + bounds.height) / m.row))
        let start = offset(ofRow: firstRow, editor, m.columns)
        let end = lastRow + 1 < place.totalRows ? offset(ofRow: lastRow + 1, editor, m.columns) : storage.length
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: Drawing

    private var colors: [RGBA: CGColor] = [:]
    private var buffer: [unichar] = []
    #if DEBUG
    /// What it drew last, for the `minimap` scenario.
    private(set) var drawnRange = NSRange(location: 0, length: 0)
    private(set) var drawnBox = NSRect.zero
    private(set) var drawnRows = 0...0
    private(set) var drawnColors: Set<String> = []
    private(set) var drawnBars = 0
    private(set) var drawMilliseconds = 0.0
    /// Where the text's view stood after each move of the last drag, for the scenario.
    private(set) var dragTops: [CGFloat] = []
    #endif

    override func draw(_ dirtyRect: NSRect) {
        let dirtyRect = dirtyRect.intersection(bounds)
        Scheme.background.setFill()
        dirtyRect.fill()
        guard let editor, let storage = editor.textView.textStorage, let context = NSGraphicsContext.current?.cgContext,
              let place = place() else { return }
        #if DEBUG
        let started = Date()
        #endif
        let m = place.metrics, text = storage.mutableString
        let firstRow = max(0, Int(place.offset / m.row)), lastRow = min(place.totalRows - 1, Int((place.offset + bounds.height) / m.row))
        let bar = max(1, m.row * 0.7)
        let styles = editor.styles, plain = Scheme.theme.foreground
        var rects: [RGBA: [CGRect]] = [:]
        var bars = 0

        // The lines in view, under a box (under the text, as Sublime's), brighter while it's held.
        Scheme.foreground.withAlphaComponent(dragging ? 0.2 : hovering ? 0.16 : 0.12).setFill()
        place.box.fill()

        // Conflict blocks (§5.4) first, under the text, in Blit's muted red (#B35C5C).
        if !editor.textView.conflictBlocks.isEmpty {
            NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 0.35).setFill()
            for block in editor.textView.conflictBlocks {
                let top = row(of: block.range.location, editor, m.columns), bottom = row(of: max(block.range.location, NSMaxRange(block.range) - 1), editor, m.columns)
                guard bottom >= firstRow, top <= lastRow else { continue }
                NSRect(x: 0, y: CGFloat(top) * m.row - place.offset, width: bounds.width, height: CGFloat(bottom - top + 1) * m.row).fill()
            }
        }

        var current = line(ofRow: firstRow)
        let starts = editor.lineIndex.starts
        var styleIndex = Self.firstEnding(after: starts[current], in: styles)
        let drawnStart = starts[current]
        var drawnEnd = drawnStart
        var rowNumber = firstRow
        while rowNumber <= lastRow, current < starts.count {
            let lineStart = starts[current]
            let lineEnd = current + 1 < starts.count ? starts[current + 1] - 1 : storage.length
            var segment = lineStart + (rowNumber - rowStarts[current]) * m.columns
            while rowNumber <= lastRow, rowNumber < rowStarts[current + 1] {
                let end = min(lineEnd, segment + m.columns)
                let y = CGFloat(rowNumber) * m.row - place.offset + (m.row - bar) / 2
                if end > segment {
                    let count = end - segment
                    if buffer.count < count { buffer = [unichar](repeating: 0, count: count) }
                    buffer.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: segment, length: count)) }
                    var column = 0, runStart = -1, runColor = plain
                    func close(at endColumn: Int) {
                        guard runStart >= 0 else { return }
                        let x = CGFloat(runStart) * m.character
                        if x < bounds.width {
                            rects[runColor, default: []].append(CGRect(x: x, y: y, width: min(CGFloat(endColumn - runStart) * m.character, bounds.width - x), height: bar))
                            bars += 1
                        }
                        runStart = -1
                    }
                    for i in 0..<count {
                        let character = buffer[i], at = segment + i
                        if character == 0x20 || character == 0x09 {
                            close(at: column)
                            column = character == 0x09 ? (column / m.tab + 1) * m.tab : column + 1
                            continue
                        }
                        while styleIndex < styles.count, NSMaxRange(styles[styleIndex].range) <= at { styleIndex += 1 }
                        let color = styleIndex < styles.count && styles[styleIndex].range.location <= at ? styles[styleIndex].style.foreground : plain
                        if runStart >= 0, color != runColor { close(at: column) }
                        if runStart < 0 { runStart = column; runColor = color }
                        column += 1
                        if CGFloat(column) * m.character >= bounds.width { break }
                    }
                    close(at: column)
                }
                drawnEnd = max(drawnEnd, end)
                rowNumber += 1
                segment = end
            }
            current += 1
        }
        for (color, list) in rects {
            context.setFillColor(cgColor(color))
            context.fill(list)
        }
        // Changes since the last commit (ED12): a column at the left edge, as in the gutter, so the
        // changes in a long file show where they are.
        let changes = editor.gitChanges
        if !changes.isEmpty {
            let width: CGFloat = 2
            for (line, kind) in changes.lines {
                guard line + 1 < rowStarts.count, rowStarts[line + 1] > firstRow, rowStarts[line] <= lastRow else { continue }
                (kind == .added ? Scheme.lineDiffAdded : Scheme.lineDiffModified).setFill()
                NSRect(x: 0, y: CGFloat(rowStarts[line]) * m.row - place.offset, width: width,
                       height: max(m.row, CGFloat(rowStarts[line + 1] - rowStarts[line]) * m.row)).fill()
            }
            Scheme.lineDiffDeleted.setFill()
            for line in changes.deletedBefore where line < rowStarts.count && rowStarts[line] >= firstRow && rowStarts[line] <= lastRow + 1 {
                NSRect(x: 0, y: CGFloat(rowStarts[line]) * m.row - place.offset - 1, width: width * 2, height: 2).fill()
            }
        }
        #if DEBUG
        drawnRange = NSRange(location: drawnStart, length: max(0, drawnEnd - drawnStart))
        drawnBox = place.box
        drawnRows = firstRow...max(firstRow, lastRow)
        drawnColors = Set(rects.keys.map(\.hex))
        drawnBars = bars
        drawMilliseconds = Date().timeIntervalSince(started) * 1000
        #endif
        editor.minimapDrew()
    }

    /// A syntax color, a little toward the background, as Sublime's minimap has them.
    private func cgColor(_ color: RGBA) -> CGColor {
        if let cached = colors[color] { return cached }
        let made = NSColor(color).withAlphaComponent(0.85 * color.a).cgColor
        colors[color] = made
        return made
    }

    private static func firstEnding(after location: Int, in styles: [(range: NSRange, style: Style)]) -> Int {
        var low = 0, high = styles.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(styles[mid].range) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Changes

    /// The text changed: its rows are worked out again, and it's drawn again a moment later
    /// (typing doesn't redraw it at every keystroke).
    func textChanged() {
        modelStale = true
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.redrawPending = false
            self?.needsDisplay = true
        }
    }

    private var redrawPending = false

    /// The scheme or the font changed: new colors, and rows at the new size.
    func schemeChanged() {
        colors = [:]
        modelStale = true
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: The mouse

    private var dragging = false
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A click in the box holds it; anywhere else, the text there comes to the middle of the
    /// view first. Then the box follows the mouse until it's let go.
    override func mouseDown(with event: NSEvent) {
        guard let editor, var place = place() else { return }
        let y = convert(event.locationInWindow, from: nil).y
        var grab = y - place.box.minY
        if !(place.box.minY...place.box.maxY).contains(y) {
            let clicked = Int((y + place.offset) / place.metrics.row)
            scroll(editor, toRow: clicked - place.visibleRows / 2, place)
            if let moved = self.place() { place = moved }
            grab = place.box.height / 2
        }
        dragging = true
        needsDisplay = true
        defer { dragging = false; needsDisplay = true }
        #if DEBUG
        dragTops = []
        #endif
        // The mouse's place becomes a row by the minimap as it stood when the button went down.
        // Worked out afresh at each move, the rows in view changed with each scroll at the very
        // end (a wrapped line in view or not), and with them the row to go to, back and forth: the
        // text shook 14 points at every move while the box stood at the foot (the user, 2026-10-06).
        // So: a scroll only for another row, and at the foot, the end of the text.
        let start = place, foot = max(0, place.totalRows - place.visibleRows)
        var went: Int?
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let top = convert(next.locationInWindow, from: nil).y - grab
            let row = min(max(0, topRow(forBoxAt: top, start)), foot)
            if row != went {
                went = row
                if row == foot, row > 0 {
                    editor.textView.reveal(editor.textView.textStorage?.length ?? 0)
                } else {
                    scroll(editor, toRow: row, start)
                }
            }
            #if DEBUG
            dragTops.append(editor.textView.visibleRect.minY)
            #endif
        }
    }

    /// The text's first row for the box at `top`: where the box stands, worked backward.
    private func topRow(forBoxAt top: CGFloat, _ place: Place) -> Int {
        let content = CGFloat(place.totalRows) * place.metrics.row
        if content > bounds.height {
            let room = max(1, bounds.height - place.box.height)
            return Int((top * CGFloat(max(0, place.totalRows - place.visibleRows)) / room).rounded())
        }
        return Int((top / place.metrics.row).rounded())
    }

    private func scroll(_ editor: Editor, toRow row: Int, _ place: Place) {
        let row = min(max(0, row), max(0, place.totalRows - place.visibleRows))
        editor.scroll(toTop: offset(ofRow: row, editor, place.metrics.columns))
    }

    #if DEBUG
    /// The line (1-based) drawn at `y`, for the scenario.
    func line(atY y: CGFloat) -> Int? {
        guard let place = place() else { return nil }
        return line(ofRow: Int((y + place.offset) / place.metrics.row)) + 1
    }

    /// A click at `y` and a drag to each of `to`, as the mouse would make them (the scenario).
    func simulateDrag(from y: CGFloat, to points: [CGFloat]) {
        guard let window else { return }
        func event(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent? {
            let point = convert(NSPoint(x: bounds.midX, y: y), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        for point in points { if let drag = event(.leftMouseDragged, point) { window.postEvent(drag, atStart: false) } }
        if let up = event(.leftMouseUp, points.last ?? y) { window.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, y) { mouseDown(with: down) }
    }
    #endif
}
