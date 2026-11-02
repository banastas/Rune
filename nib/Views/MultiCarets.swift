// Multiple carets (PRD ED8), as Sublime has them: ⌘-click adds one (or takes one away), ⌥-drag
// makes a column, ⌘D adds the next occurrence of the selection (from a caret, its word first),
// ⌃⌘G selects every occurrence, ⇧⌘L splits a selection into its lines, ⌃⇧↑ and ⌃⇧↓ add one on
// the line above or below; Escape goes back to one. Typing, deleting, Return (kept indentation),
// Tab, the arrows with ⌥, ⌘ and ⇧, copy, cut and paste, and the line commands (Indent, Toggle
// Comment, Duplicate, Join, Select and Move Line) work at every caret, each edit one undo step
// (a run of typing, one). NSTextView has one insertion point, so this is Nib's own:
// NibText's `Carets` does the arithmetic; the text view keeps its own selection on the primary
// caret (the strip's line and column, scrolling and find follow it), draws the others (system
// insertion indicators for the carets, the selection color under the text for selections), and
// makes the edits with undo steps of its own that put every caret back. Anything it doesn't do
// at several carets (⌘A, a plain click, Page Down) goes back to one caret, then works as ever.
// Undo Selection (⌘U) takes back the last change to the carets since the last edit, and Redo
// Selection (⇧⌘U) puts it back (NibText's `CaretHistory`).

import AppKit
import NibText

/// One edit at every caret, for undo: what was made, what it replaced, the carets either side.
struct CaretStep {
    var edits: [Edit]
    var replaced: [String]
    var before: Carets
    var after: Carets
}

/// One undo step: an edit, or a run of typing that goes on while nothing else happens.
final class CaretRun {
    var steps: [CaretStep]
    var open = true
    init(_ step: CaretStep) { steps = [step] }
}

extension NibTextView {
    /// More than one caret.
    var multi: Bool { (carets?.count ?? 0) > 1 }

    /// The carets as they are: several, or the text view's own one.
    var currentCarets: Carets {
        if let carets, carets.count > 1 { return carets }
        let range = selectedRange()
        return Carets([Caret(anchor: range.location, head: NSMaxRange(range))])
    }

    /// Several carets, drawn here, the primary as the text view's own selection; or one, the text
    /// view's own again. `scroll`: the primary into view.
    func setCarets(_ new: Carets?, scroll: Bool = true) {
        settingCarets += 1
        defer { settingCarets -= 1 }
        if let new, new.count > 1 {
            carets = new
            setSelectedRange(new.primaryCaret.range)
        } else {
            carets = nil
            if let new { setSelectedRange(new.primaryCaret.range) }
        }
        caretsChanged()
        if scroll { reveal(new.map { $0.primaryCaret.head } ?? selectedRange().location) }
    }

    /// Back to one caret, the primary.
    func collapseCarets() {
        guard let carets else { return }
        setCarets(Carets([carets.primaryCaret]), scroll: false)
    }

    /// The carets moved or went: the drawing, the strip's count, and no typing run across it.
    func caretsChanged() {
        if typingRun?.steps.last?.after != carets { typingRun?.open = false }
        updateCaretViews()
        needsDisplay = true
        onCarets?(carets?.count ?? 1)
        noteCarets()
    }

    // MARK: Drawing

    /// The characters in TextKit 2's viewport, as offsets: the other carets are drawn there only
    /// (Find All can make 10,000), and placed again as it scrolls.
    func viewportSpan() -> ClosedRange<Int> {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return 0...(string as NSString).length }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        return start...(start + content.offset(from: viewport.location, to: viewport.endLocation))
    }

    /// The system's own insertion indicator at each caret in view but the primary (the text view draws that).
    func updateCaretViews() {
        var heads: [Int] = []
        if let carets, carets.count > 1 {
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            let span = viewportSpan()
            heads = carets.all.indices.filter { $0 != carets.primary && span.contains(carets.all[$0].head) }.map { carets.all[$0].head }
        }
        while caretViews.count < heads.count {
            let indicator = NSTextInsertionIndicator(frame: .zero)
            indicator.color = insertionPointColor
            addSubview(indicator)
            caretViews.append(indicator)
        }
        while caretViews.count > heads.count { caretViews.removeLast().removeFromSuperview() }
        for (indicator, head) in zip(caretViews, heads) {
            if let rect = caretRect(at: head) {
                indicator.frame = rect
                indicator.displayMode = .automatic
            } else {
                indicator.displayMode = .hidden
            }
        }
    }

    /// Where a caret at `location` stands, in the view: the insertion point's rect.
    func caretRect(at location: Int) -> NSRect? {
        guard let layout = textLayoutManager, let range = textRange(NSRange(location: location, length: 0)) else { return nil }
        // The viewport laid out now: after edits TextKit 2 lays out lazily, and a line not
        // placed yet gave the line above's place (a ⌘-click landing a line up, the `carets`
        // scenario). Off screen, places are estimates until scrolled to (the carets are
        // placed again then).
        layout.textViewportLayoutController.layoutViewport()
        var found: NSRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        if found == nil, location == (string as NSString).length, location > 0, let before = caretRect(at: location - 1) {
            // The very end, after a final line feed: the start of the empty last line.
            found = (string as NSString).character(at: location - 1) == 0x0A
                ? NSRect(x: 0, y: before.maxY - textContainerOrigin.y, width: 0, height: before.height)
                : NSRect(x: before.maxX - textContainerOrigin.x, y: before.minY - textContainerOrigin.y, width: 0, height: before.height)
        }
        guard var rect = found else { return nil }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        rect.size.width = max(rect.width, 2)
        if rect.height < 1 { rect.size.height = Scheme.font.ascender - Scheme.font.descender + Scheme.font.leading }
        return rect
    }

    /// The other carets' selections, in the selection color, under the text (the text view draws the primary's).
    func drawOtherSelections(in rect: NSRect) {
        guard let carets, carets.count > 1, let layout = textLayoutManager else { return }
        let origin = textContainerOrigin, span = viewportSpan()
        Scheme.selection.setFill()
        for (index, caret) in carets.all.enumerated() where index != carets.primary && !caret.isEmpty
            && NSMaxRange(caret.range) >= span.lowerBound && caret.range.location <= span.upperBound {
            guard let range = textRange(caret.range) else { continue }
            layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
                let box = frame.offsetBy(dx: origin.x, dy: origin.y)
                if box.intersects(rect) { box.intersection(rect).fill() }
                return true
            }
        }
    }

    // MARK: Edits

    /// Edits at every caret as one undo step (or one more keystroke of a typing run), and the
    /// carets after. Undo puts the text and every caret back; redo makes it all again.
    func perform(_ edits: [Edit], then after: Carets, action: String, typing: Bool = false) {
        guard !edits.isEmpty else { setCarets(after); return }
        let before = currentCarets, text = string as NSString
        let step = CaretStep(edits: edits, replaced: edits.map { text.substring(with: $0.range) }, before: before, after: after)
        guard make(edits) else { return }
        if typing, let run = typingRun, run.open, run.steps.last?.after == before {
            run.steps.append(step)   // the run's undo step takes it back with the rest
        } else {
            let run = CaretRun(step)
            typingRun = typing ? run : nil
            registerUndo(of: run, action: action)
        }
        setCarets(after)
    }

    /// The edits, made as one change (the delegate told of every range), with no undo of the
    /// text view's own. False if the text view won't take them (read-only, say).
    private func make(_ edits: [Edit]) -> Bool {
        settingCarets += 1
        defer { settingCarets -= 1 }
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }
        guard shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.replacement)) else { return false }
        textStorage?.beginEditing()
        for edit in edits.reversed() { textStorage?.replaceCharacters(in: edit.range, with: edit.replacement) }
        textStorage?.endEditing()
        didChangeText()
        return true
    }

    /// A step's edits taken back: in the text as it is after it, each made what it replaced.
    private static func inverse(of step: CaretStep) -> [Edit] {
        var shift = 0
        return zip(step.edits, step.replaced).map { edit, old in
            let length = (edit.replacement as NSString).length
            let made = NSRange(location: edit.range.location + shift, length: length)
            shift += length - edit.range.length
            return Edit(range: made, replacement: old)
        }
    }

    private func registerUndo(of run: CaretRun, action: String) {
        undoManager?.registerUndo(withTarget: self) { view in view.undo(run, action: action) }
        undoManager?.setActionName(action)
        breakUndoCoalescing()
    }

    private func undo(_ run: CaretRun, action: String) {
        run.open = false
        typingRun = nil
        // Only over the text it made: if the text changed under it since (a version from
        // another Mac put in without an undo step), taking it back would garble it.
        let text = string as NSString
        var intact = true
        if let last = run.steps.last {
            for (edit, made) in zip(last.edits, Self.inverse(of: last)) where NSMaxRange(made.range) > text.length || text.substring(with: made.range) != edit.replacement {
                intact = false
            }
        }
        guard intact else {
            NSSound.beep()
            undoManager?.removeAllActions(withTarget: self)
            return
        }
        for step in run.steps.reversed() { _ = make(Self.inverse(of: step)) }
        setCarets(run.steps[0].before)
        undoManager?.registerUndo(withTarget: self) { view in view.redo(run, action: action) }
        undoManager?.setActionName(action)
    }

    private func redo(_ run: CaretRun, action: String) {
        for step in run.steps { _ = make(step.edits) }
        setCarets(run.steps[run.steps.count - 1].after)
        undoManager?.registerUndo(withTarget: self) { view in view.undo(run, action: action) }
        undoManager?.setActionName(action)
    }

    /// A line command at every caret (⌘], ⌘[, ⌘/, ⇧⌘D, ⌘J, ⌃⌘↑, ⌃⌘↓), one undo step: carets on
    /// the same lines share it, so a line is indented once however many carets are on it.
    func lineCommandAtCarets(_ action: String, groups: Carets.LineGroups, _ make: (NSRange) -> LineEdit?) {
        guard let result = currentCarets.lineEdits(in: string, groups: groups, make) else { NSSound.beep(); return }
        perform(result.edits, then: result.after, action: action)
    }

    /// Typing at every caret.
    func typeAtCarets(_ text: String) {
        guard let storage = textStorage else { return }
        let (edits, after) = currentCarets.typing(text, in: storage.mutableString, pairs: autoPairs)
        perform(edits, then: after, action: "Typing", typing: true)
    }

    // MARK: Commands

    /// A command from the keys, at every caret: true if it's one done here.
    func multiCaretCommand(_ selector: Selector) -> Bool {
        let text = string as NSString
        switch selector {
        case #selector(cancelOperation(_:)):
            collapseCarets()
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)):
            // Return keeps each line's indentation (Sublime's auto-indent).
            let texts = currentCarets.all.map { caret -> String in
                let line = text.lineRange(for: NSRange(location: caret.range.location, length: 0))
                let before = text.substring(with: NSRange(location: line.location, length: caret.range.location - line.location))
                return "\n" + before.prefix { $0 == " " || $0 == "\t" }
            }
            let (edits, after) = currentCarets.replacing(with: texts)
            perform(edits, then: after, action: "Typing", typing: true)
        case #selector(insertTab(_:)):
            // A selection over several lines at any caret: Indent at every one (as on one caret).
            if currentCarets.all.contains(where: { $0.range.length > 0 && text.range(of: "\n", range: $0.range).location != NSNotFound }) {
                indentLines(nil)
                return true
            }
            let texts = currentCarets.all.map { caret -> String in
                guard case .spaces(let width) = indentation else { return "\t" }
                let line = text.lineRange(for: NSRange(location: caret.range.location, length: 0))
                return String(repeating: " ", count: width - (caret.range.location - line.location) % width)
            }
            let (edits, after) = currentCarets.replacing(with: texts)
            perform(edits, then: after, action: "Typing", typing: true)
        case #selector(insertBacktab(_:)):
            outdentLines(nil)
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)):
            let pairs = autoPairs
            delete("Delete") { head in
                (pairs ? AutoPairs.deleting(in: text, caret: head) : nil) ?? (head == 0 ? nil : text.rangeOfComposedCharacterSequence(at: head - 1))
            }
        case #selector(deleteForward(_:)):
            delete("Delete") { $0 >= text.length ? nil : text.rangeOfComposedCharacterSequence(at: $0) }
        case #selector(deleteWordBackward(_:)):
            delete("Delete Word") { head in
                let start = self.word(from: head, forward: false)
                return NSRange(location: start, length: head - start)
            }
        case #selector(deleteWordForward(_:)):
            delete("Delete Word") { NSRange(location: $0, length: self.word(from: $0, forward: true) - $0) }
        case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)):
            delete("Delete to Line Start") { head in
                let start = self.visualLine(at: head).location
                return NSRange(location: start, length: head - start)
            }
        case #selector(deleteToEndOfLine(_:)), #selector(deleteToEndOfParagraph(_:)):
            delete("Delete to Line End") { NSRange(location: $0, length: max(0, self.lineEnd(at: $0) - $0)) }
        default:
            guard let move = Self.moves[selector] else { return false }
            moveCarets(move.0, extending: move.1)
        }
        return true
    }

    private func delete(_ action: String, _ span: (Int) -> NSRange?) {
        let (edits, after) = currentCarets.deleting(span)
        perform(edits, then: after, action: action)
    }

    /// The paragraph moves are a logical line's (⌃A, ⌃E; ⌥↑ and ⌥↓ step back or on a character
    /// first), the line moves a wrapped line's.
    enum Move { case left, right, up, down, wordLeft, wordRight, lineStart, lineEnd, paragraphStart, paragraphEnd, paragraphBackward, paragraphForward, documentStart, documentEnd }

    /// The keys' moves, and whether each extends the selection.
    static let moves: [Selector: (Move, Bool)] = [
        #selector(moveLeft(_:)): (.left, false), #selector(moveBackward(_:)): (.left, false),
        #selector(moveRight(_:)): (.right, false), #selector(moveForward(_:)): (.right, false),
        #selector(moveUp(_:)): (.up, false), #selector(moveDown(_:)): (.down, false),
        #selector(moveWordLeft(_:)): (.wordLeft, false), #selector(moveWordBackward(_:)): (.wordLeft, false),
        #selector(moveWordRight(_:)): (.wordRight, false), #selector(moveWordForward(_:)): (.wordRight, false),
        #selector(moveToBeginningOfLine(_:)): (.lineStart, false), #selector(moveToLeftEndOfLine(_:)): (.lineStart, false),
        #selector(moveToEndOfLine(_:)): (.lineEnd, false), #selector(moveToRightEndOfLine(_:)): (.lineEnd, false),
        #selector(moveToBeginningOfDocument(_:)): (.documentStart, false), #selector(moveToEndOfDocument(_:)): (.documentEnd, false),
        #selector(moveLeftAndModifySelection(_:)): (.left, true), #selector(moveBackwardAndModifySelection(_:)): (.left, true),
        #selector(moveRightAndModifySelection(_:)): (.right, true), #selector(moveForwardAndModifySelection(_:)): (.right, true),
        #selector(moveUpAndModifySelection(_:)): (.up, true), #selector(moveDownAndModifySelection(_:)): (.down, true),
        #selector(moveWordLeftAndModifySelection(_:)): (.wordLeft, true), #selector(moveWordBackwardAndModifySelection(_:)): (.wordLeft, true),
        #selector(moveWordRightAndModifySelection(_:)): (.wordRight, true), #selector(moveWordForwardAndModifySelection(_:)): (.wordRight, true),
        #selector(moveToBeginningOfLineAndModifySelection(_:)): (.lineStart, true), #selector(moveToLeftEndOfLineAndModifySelection(_:)): (.lineStart, true),
        #selector(moveToEndOfLineAndModifySelection(_:)): (.lineEnd, true), #selector(moveToRightEndOfLineAndModifySelection(_:)): (.lineEnd, true),
        // ⌃A, ⌃E, ⌥↑, ⌥↓ and ⇧⌥↑, ⇧⌥↓ (macOS's paragraph moves): they collapsed the carets to one (the QA
        // review's F30, 2026-10-07).
        #selector(moveToBeginningOfParagraph(_:)): (.paragraphStart, false), #selector(moveToEndOfParagraph(_:)): (.paragraphEnd, false),
        #selector(moveToBeginningOfParagraphAndModifySelection(_:)): (.paragraphStart, true),
        #selector(moveToEndOfParagraphAndModifySelection(_:)): (.paragraphEnd, true),
        #selector(moveParagraphBackwardAndModifySelection(_:)): (.paragraphBackward, true),
        #selector(moveParagraphForwardAndModifySelection(_:)): (.paragraphForward, true),
        #selector(moveToBeginningOfDocumentAndModifySelection(_:)): (.documentStart, true), #selector(moveToEndOfDocumentAndModifySelection(_:)): (.documentEnd, true),
    ]

    func moveCarets(_ move: Move, extending: Bool) {
        let length = (string as NSString).length
        setCarets(currentCarets.moving { caret in
            // Moved, not extended, a selection collapses to the side it's moving to (as on one caret).
            if !extending, !caret.isEmpty, move == .left || move == .right {
                let to = move == .left ? caret.range.location : NSMaxRange(caret.range)
                return Caret(to)
            }
            if move == .up || move == .down { return vertical(caret, up: move == .up, extending: extending) }
            let backward: Set<Move> = [.left, .wordLeft, .lineStart, .paragraphStart, .paragraphBackward]
            let from = extending ? caret.head : (backward.contains(move) ? caret.range.location : NSMaxRange(caret.range))
            let to: Int
            switch move {
            case .left: to = from == 0 ? 0 : (string as NSString).rangeOfComposedCharacterSequence(at: from - 1).location
            case .right: to = from >= length ? length : NSMaxRange((string as NSString).rangeOfComposedCharacterSequence(at: from))
            case .wordLeft: to = word(from: from, forward: false)
            case .wordRight: to = word(from: from, forward: true)
            case .lineStart: to = visualLine(at: from).location
            case .lineEnd: to = lineEnd(at: from)
            case .paragraphStart: to = paragraph(at: from).location
            case .paragraphEnd: to = paragraphEnd(at: from)
            case .paragraphBackward:
                let start = paragraph(at: from).location
                to = from == start && from > 0 ? paragraph(at: from - 1).location : start
            case .paragraphForward:
                let end = paragraphEnd(at: from)
                to = from == end && from < length ? paragraphEnd(at: from + 1) : end
            case .documentStart: to = 0
            case .documentEnd: to = length
            case .up, .down: to = from
            }
            return extending ? Caret(anchor: caret.anchor, head: to) : Caret(to)
        })
    }

    /// The logical line (paragraph) a place is in, with its line break.
    private func paragraph(at location: Int) -> NSRange {
        (string as NSString).paragraphRange(for: NSRange(location: min(location, (string as NSString).length), length: 0))
    }

    /// Where a paragraph's text ends, before its line break.
    private func paragraphEnd(at location: Int) -> Int {
        let text = string as NSString, range = paragraph(at: location)
        var end = NSMaxRange(range)
        while end > range.location, let scalar = UnicodeScalar(text.character(at: end - 1)), CharacterSet.newlines.contains(scalar) { end -= 1 }
        return end
    }

    /// ↑ or ↓ from a caret, keeping to its goal x past shorter lines; off the first line, the
    /// start of the text; off the last, its end (as on one caret).
    func vertical(_ caret: Caret, up: Bool, extending: Bool) -> Caret {
        let from = extending ? caret.head : (up ? caret.range.location : NSMaxRange(caret.range))
        let length = (string as NSString).length
        guard let rect = caretRect(at: from) else { return caret }
        let x = caret.goal ?? Double(rect.minX)
        let y = up ? rect.minY - rect.height / 2 : rect.maxY + rect.height / 2
        var to = characterIndexForInsertion(at: NSPoint(x: x, y: y))
        if to == NSNotFound { to = from }
        // Not moved off its line: it was the first (or last) one.
        if let there = caretRect(at: to), abs(there.midY - rect.midY) < rect.height / 2 { to = up ? 0 : length }
        return extending ? Caret(anchor: caret.anchor, head: to, goal: x) : Caret(anchor: to, head: to, goal: x)
    }

    /// The next word boundary, as ⌥← and ⌥→ find it.
    func word(from location: Int, forward: Bool) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }
        if forward, location >= storage.length { return storage.length }
        if !forward, location <= 0 { return 0 }
        return storage.nextWord(from: location, forward: forward)
    }

    /// The visual line a location is on (a wrapped line's row), from TextKit 2's line fragments.
    func visualLine(at location: Int) -> NSRange {
        let text = string as NSString, length = text.length
        let paragraph = text.lineRange(for: NSRange(location: min(location, length), length: 0))
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let at = content.location(content.documentRange.location, offsetBy: min(location, length)),
              let fragment = layout.textLayoutFragment(for: at) else { return paragraph }
        let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let offset = location - start
        for line in fragment.textLineFragments {
            let range = line.characterRange
            if offset >= range.location, offset < NSMaxRange(range) || line === fragment.textLineFragments.last {
                return NSRange(location: start + range.location, length: range.length)
            }
        }
        return paragraph
    }

    /// The end of a location's visual line, before its line feed.
    func lineEnd(at location: Int) -> Int {
        let text = string as NSString, line = visualLine(at: location)
        var end = NSMaxRange(line)
        if end > line.location, end <= text.length, text.character(at: end - 1) == 0x0A { end -= 1 }
        return max(end, min(location, end))
    }

    // MARK: Selection menu

    /// ⌘D: from carets, each one's word; then the next occurrence of the primary selection's text
    /// (a whole word, if it came from one), a caret more.
    @objc func selectNextOccurrence(_ sender: Any?) {
        let text = string as NSString, carets = currentCarets
        if carets.all.allSatisfy(\.isEmpty) {
            let words = carets.all.compactMap { Occurrences.word(at: $0.head, in: text).map(Caret.init(range:)) }
            guard !words.isEmpty else { NSSound.beep(); return }
            wholeWordSearch = true
            let selected = Carets(words)
            expandedWord = selected.count == 1 ? selected.primaryCaret.range : nil
            setCarets(selected)
            return
        }
        // One selection: whole words if it's the word ⌘D picked, any occurrence if it's the user's own.
        if !multi { wholeWordSearch = expandedWord == carets.primaryCaret.range }
        let needle = text.substring(with: carets.primaryCaret.range)
        guard let found = Occurrences.next(needle, in: text, after: NSMaxRange(carets.primaryCaret.range), wholeWord: wholeWordSearch, taken: carets.ranges) else {
            NSSound.beep()
            onNotice?("NO MORE OF “\(needle.count > 30 ? needle.prefix(30) + "…" : needle)” · \(carets.count) SELECTED")
            return
        }
        setCarets(carets.adding(Caret(range: found)))
    }

    /// Selection › Skip to Next Occurrence (Sublime's ⌘K ⌘D; the ⌘K chords wait for open
    /// question 10): the last selection ⌘D added goes, and the next occurrence after it comes in
    /// its place. From a caret, its word, as ⌘D.
    @objc func skipToNextOccurrence(_ sender: Any?) {
        let text = string as NSString, carets = currentCarets, primary = carets.primaryCaret
        guard !primary.isEmpty else { selectNextOccurrence(sender); return }
        if !multi { wholeWordSearch = expandedWord == primary.range }
        let needle = text.substring(with: primary.range)
        let others = carets.all.indices.filter { $0 != carets.primary }.map { carets.all[$0].range }
        guard let found = Occurrences.next(needle, in: text, after: NSMaxRange(primary.range), wholeWord: wholeWordSearch, taken: others),
              found != primary.range else {
            NSSound.beep()
            onNotice?("NO MORE OF “\(needle.count > 30 ? needle.prefix(30) + "…" : needle)” · \(carets.count) SELECTED")
            return
        }
        if !multi { expandedWord = wholeWordSearch ? found : nil }
        setCarets(carets.replacingPrimary(with: Caret(range: found)))
    }

    /// ⌃⌘G: every occurrence of the selection's text (of the caret's word, a whole word).
    @objc func selectAllOccurrences(_ sender: Any?) {
        let text = string as NSString, carets = currentCarets, primary = carets.primaryCaret
        let range: NSRange, whole: Bool
        if primary.isEmpty {
            guard let word = Occurrences.word(at: primary.head, in: text) else { NSSound.beep(); return }
            (range, whole) = (word, true)
        } else {
            (range, whole) = (primary.range, multi ? wholeWordSearch : expandedWord == primary.range)
        }
        let found = Occurrences.all(text.substring(with: range), in: text, wholeWord: whole)
        guard !found.isEmpty else { NSSound.beep(); return }
        wholeWordSearch = whole
        let at = found.firstIndex { $0.location >= range.location } ?? 0
        setCarets(Carets(found.map(Caret.init(range:)), primary: at))
        onNotice?("\(found.count) SELECTED")
    }

    /// Selection › One Caret (and Escape): the primary.
    @objc func singleCaret(_ sender: Any?) { collapseCarets() }

    /// ⇧⌘L: each selection a selection a line.
    @objc func splitSelectionIntoLines(_ sender: Any?) {
        setCarets(currentCarets.splitIntoLines(in: string as NSString))
    }

    /// ⌃⇧↑ and ⌃⇧↓: a caret more on the line above the top one, or below the bottom one.
    @objc func addCaretAbove(_ sender: Any?) { addCaret(up: true) }
    @objc func addCaretBelow(_ sender: Any?) { addCaret(up: false) }

    private func addCaret(up: Bool) {
        let carets = currentCarets
        guard let edge = up ? carets.all.first : carets.all.last else { return }
        let next = vertical(Caret(anchor: edge.head, head: edge.head, goal: edge.goal), up: up, extending: false)
        guard next.head != edge.head else { NSSound.beep(); return }
        setCarets(carets.adding(next))
    }

    // MARK: The mouse

    /// ⌘-click: a caret more there, or the one there gone; held and dragged, it selects.
    func commandClick(_ event: NSEvent) {
        trackingMouse = true
        defer { trackingMouse = false; noteCarets() }   // the click and its drag, one step
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let carets = currentCarets
        if let fewer = carets.removing(at: index) {
            setCarets(fewer, scroll: false)
            track { _ in }   // the press, to its end: one press, one mouse-up
            return
        }
        setCarets(carets.adding(Caret(index)), scroll: false)
        track { point in
            let head = self.characterIndexForInsertion(at: point)
            self.setCarets(self.currentCarets.replacingPrimary(with: Caret(anchor: index, head: head)), scroll: false)
        }
    }

    /// ⌥-drag: a column, a selection a line from where the drag began to where it is (a line too
    /// short for it, a caret at its end). False when the mouse didn't move: a plain click.
    func columnDrag(_ event: NSEvent) -> Bool {
        trackingMouse = true
        defer { trackingMouse = false; noteCarets() }
        let start = convert(event.locationInWindow, from: nil)
        var moved = false
        track { point in
            if !moved, hypot(point.x - start.x, point.y - start.y) < 4 { return }
            moved = true
            self.setCarets(self.column(from: start, to: point), scroll: false)
        }
        if !moved { setCarets(Carets([Caret(characterIndexForInsertion(at: start))]), scroll: false) }
        return true
    }

    private func column(from a: NSPoint, to b: NSPoint) -> Carets {
        let top = min(a.y, b.y), bottom = max(a.y, b.y)
        var carets: [Caret] = []
        for y in visualLineMiddles(from: top, to: bottom) {
            carets.append(Caret(anchor: characterIndexForInsertion(at: NSPoint(x: a.x, y: y)),
                                head: characterIndexForInsertion(at: NSPoint(x: b.x, y: y))))
        }
        guard !carets.isEmpty else { return currentCarets }
        return Carets(carets, primary: b.y >= a.y ? carets.count - 1 : 0)
    }

    /// The middle of each visual line between two heights, in the view.
    private func visualLineMiddles(from top: CGFloat, to bottom: CGFloat) -> [CGFloat] {
        guard let layout = textLayoutManager else { return [] }
        let origin = textContainerOrigin
        var middles: [CGFloat] = []
        let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top - origin.y)))?.rangeInElement.location ?? layout.documentRange.location
        layout.enumerateTextLayoutFragments(from: first, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            for line in fragment.textLineFragments {
                let bounds = line.typographicBounds
                let middle = origin.y + frame.minY + bounds.midY
                if origin.y + frame.minY + bounds.maxY >= top, origin.y + frame.minY + bounds.minY <= bottom { middles.append(middle) }
            }
            return origin.y + frame.maxY <= bottom
        }
        return middles
    }

    /// The mouse held down: `update` as it moves, or as the view scrolls under it (a trackpad's
    /// scroll while it's held), until it's let go.
    private func track(_ update: (NSPoint) -> Void) {
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel]) {
            if event.type == .scrollWheel { enclosingScrollView?.scrollWheel(with: event) }
            update(convert(event.locationInWindow, from: nil))
            if event.type == .leftMouseUp { break }
            if event.type == .leftMouseDragged { autoscroll(with: event) }
        }
    }

    // MARK: Undo Selection (⌘U, ⇧⌘U)

    /// A change to the carets, for Undo Selection: from a key, a click or a command. Not while
    /// Undo Selection puts carets back, or while the mouse is held (its end counts), and not the
    /// carets an edit moves: an edit starts the steps over.
    func noteCarets() {
        guard restoringCarets == 0, !trackingMouse, !caretSettlePending else { return }
        caretHistory.changed(to: currentCarets)
    }

    /// The characters changed: the steps were for the text before. They start over from the
    /// carets the change leaves, once it's done: an edit sets the selection more than once on its
    /// way (⌘Z puts the text back, then the carets), and none of those is a step.
    func textChangedForCarets() {
        guard !caretSettlePending else { return }
        caretSettlePending = true
        DispatchQueue.main.async { [weak self] in self?.settleCaretsAfterEdit() }
    }

    private func settleCaretsAfterEdit() {
        guard caretSettlePending else { return }
        caretSettlePending = false
        caretHistory.textChanged(carets: currentCarets)
    }

    /// ⌘U: the carets as they were before their last change since the last edit (Sublime's soft
    /// undo, without the edits: ⌘Z takes those back).
    @objc func undoSelection(_ sender: Any?) {
        settleCaretsAfterEdit()   // an edit just now: nothing to take back
        guard let previous = caretHistory.undo() else { NSSound.beep(); return }
        restoreCarets(previous)
    }

    /// ⇧⌘U: the carets Undo Selection last took back.
    @objc func redoSelection(_ sender: Any?) {
        settleCaretsAfterEdit()
        guard let next = caretHistory.redo() else { NSSound.beep(); return }
        restoreCarets(next)
    }

    private func restoreCarets(_ carets: Carets) {
        // Steps are for the text as it is (an edit starts them over), so each fits; if not, none.
        guard NSMaxRange(carets.all[carets.count - 1].range) <= (string as NSString).length else {
            caretHistory = CaretHistory()
            NSSound.beep()
            return
        }
        restoringCarets += 1
        defer { restoringCarets -= 1 }
        setCarets(carets)
    }

    // MARK: The clipboard

    /// Copy: the selections' text, a line each (nothing selected, nothing to copy).
    func copyAtCarets() -> Bool {
        guard let carets, carets.count > 1 else { return false }
        let text = string as NSString
        let parts = carets.all.filter { !$0.isEmpty }.map { text.substring(with: $0.range) }
        guard !parts.isEmpty else { NSSound.beep(); return true }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n"), forType: .string)
        return true
    }

    /// Paste: as many lines as carets, a line each (as Sublime does); else all of it at each.
    func pasteAtCarets(_ text: String) {
        let carets = currentCarets
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let (edits, after) = carets.replacing(with: lines.count == carets.count ? lines : [text])
        perform(edits, then: after, action: "Paste")
    }
}
