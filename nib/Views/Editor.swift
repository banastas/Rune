// The text view (PRD ED1, §6.3): NSTextView on TextKit 2, plain text only, in the
// scheme's colors (HL5), redrawn when the scheme or font changes. One instance lives as
// long as the document, so closing and reopening the window keeps the buffer, the undo
// stack and the selection.
// Nothing here touches `layoutManager`, which would silently switch it to TextKit 1.

import AppKit
import NibSyntax
import NibText

@MainActor
final class Editor: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView: NSScrollView
    let textView: NibTextView
    weak var document: Document?
    /// The editor's own undo history (ED1): it lives as long as the buffer, so closing and
    /// reopening the window keeps it. (Inside SwiftUI's window the text view had none.)
    let undo = UndoManager()

    override init() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Scheme.background
        scrollView.scrollerStyle = .overlay
        textView = NibTextView(usingTextLayoutManager: true)
        super.init()
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = Scheme.font
        textView.textColor = Scheme.foreground
        textView.backgroundColor = Scheme.background
        textView.insertionPointColor = Scheme.caret
        textView.selectedTextAttributes = [.backgroundColor: Scheme.selection]
        textView.typingAttributes = [.font: Scheme.font, .foregroundColor: Scheme.foreground]
        textView.delegate = self
        textView.textStorage?.delegate = self   // the caret's line count follows edits (position(of:))
        textView.onEscape = { [weak self] in self?.document?.hideBanner() ?? false }
        textView.setAccessibilityLabel("Scratch")
        scrollView.documentView = textView
        // Scrolling brings new text into view: render it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        NotificationCenter.default.addObserver(forName: .nibSchemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyScheme() }
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    private var highlighted: [ConflictBlock] = []

    /// Conflict blocks (§5.4): the text view draws each as a HUD frame on a panel, and the
    /// marker lines' own text is hidden under it (in render), so the file keeps plain markers
    /// that any editor can read.
    func highlight(_ blocks: [ConflictBlock]) {
        guard !(blocks.isEmpty && highlighted.isEmpty) else { return }
        highlighted = blocks
        textView.conflictBlocks = blocks
        render(force: true)
    }

    /// For an editor with no document (the merge view's result): told of changes and caret moves.
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?

    func textDidChange(_ notification: Notification) {
        document?.textDidChange()
        onChange?()
        scheduleHighlight()
    }

    /// Before each change: the colors move with the text until the next highlight, so typing
    /// doesn't shift them a character off for a moment.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        let inserted = (text as NSString?)?.length ?? 0, change = inserted - range.length
        guard change != 0 || range.length > 0 else { return true }
        styles = styles.compactMap { item in
            var (r, style) = item
            let end = NSMaxRange(r), editEnd = NSMaxRange(range)
            if r.location >= editEnd {
                r.location += change                                    // after the edit: moves
            } else if r.location <= range.location, end >= editEnd {
                r.length += change                                      // holds the edit: grows or shrinks
            } else if r.location < range.location {
                r.length = range.location - r.location                  // cut by it: what came before
            } else {
                r = NSRange(location: range.location + inserted, length: end - editEnd)   // its tail, after the new text
            }
            return r.length > 0 ? (r, style) : nil
        }
        return true
    }

    // MARK: Highlighting (HL1, §6.3)

    /// The file's syntax, from its name and first line; nil is plain text. Set once the text is in.
    var syntax: (language: SyntaxLanguage, root: String)? {
        didSet {
            syntaxDocument = syntax.map { SyntaxDocument(language: $0.language, root: $0.root) }
            scheduleHighlight(after: 0)
        }
    }
    /// The tree, kept across edits, and the styles worked out for `styled`: the text in view
    /// with a wider margin than `render` draws, so scrolling a little needs nothing new (§6.3).
    private var syntaxDocument: SyntaxDocument?
    private var styles: [(range: NSRange, style: Style)] = []
    private var styled = NSRange(location: 0, length: 0)
    private var highlightTask: Task<Void, Never>?
    private var highlightPending = false
    private var edits = 0
    private var rendered = NSRange(location: 0, length: 0)

    /// The scheme or the font changed (Settings › Themes, Import from Sublime Text): the new
    /// colors and font everywhere. Attributes only, so it isn't an edit and nothing is saved.
    func applyScheme() {
        scrollView.backgroundColor = Scheme.background
        textView.backgroundColor = Scheme.background
        textView.insertionPointColor = Scheme.caret
        textView.selectedTextAttributes = [.backgroundColor: Scheme.selection]
        if faces.regular != Scheme.font {
            faces = Self.faces(of: Scheme.font)
            textView.font = Scheme.font
        }
        textView.textColor = Scheme.foreground
        textView.typingAttributes = [.font: Scheme.font, .foregroundColor: Scheme.foreground]
        rendered = NSRange(location: 0, length: 0)
        scheduleHighlight(after: 0)
        render(force: true)
        textView.needsDisplay = true
    }

    /// A moment after typing pauses, off the main thread: the tree brought up to the text (an
    /// incremental parse: 30-110 ms at 2.4-5 MB, a whole one only when a file opens), then the
    /// styles of the text in view and a margin (7-28 ms). Up to 5 MB (ED9: larger files
    /// aren't highlighted).
    func scheduleHighlight(after delay: Double = 0.08) {
        edits += 1
        highlightTask?.cancel()
        let version = edits
        guard let syntaxDocument, (textView.string as NSString).length <= 5_000_000 else {
            highlightPending = false
            if !styles.isEmpty { styles = []; styled = NSRange(location: 0, length: 0); render(force: true) }
            return
        }
        highlightPending = true
        highlightTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            // The text as it is now, masked for parsing (a snapshot: typing goes on meanwhile).
            let text = ConflictText.masked(self.textView.string, blocks: self.textView.conflictBlocks)
            let window = self.styleWindow(), theme = Scheme.theme
            await syntaxDocument.update(text)
            let result = await syntaxDocument.styles(in: window, theme: theme)
            guard !Task.isCancelled, version == self.edits else { return }   // a newer one is on its way
            self.highlightPending = false
            self.styles = result
            self.styled = window
            self.render(force: true)
        }
    }

    /// The text in view, with 12,000 characters either side (`render` draws 3,000 either side).
    private func styleWindow() -> NSRange {
        let view = visibleRange(), length = (textView.string as NSString).length
        return NSIntersectionRange(NSRange(location: max(0, view.location - 12_000), length: view.length + 24_000), NSRange(location: 0, length: length))
    }

    /// The text in view, and a margin: syntax colors and backgrounds as rendering attributes
    /// (§6.3: never the text storage, undo or layout), then the conflict frames' hidden marker
    /// lines; bold, italic and underline, which rendering attributes can't carry, as faces.
    func render(force: Bool = false) {
        guard let layout = textView.textLayoutManager else { return }
        let length = (textView.string as NSString).length
        let view = visibleRange()
        let wanted = NSIntersectionRange(NSRange(location: max(0, view.location - 3_000), length: view.length + 6_000), NSRange(location: 0, length: length))
        if !force, NSIntersectionRange(wanted, rendered).length == wanted.length, wanted.length > 0 { return }
        // Scrolled past what's styled: that stretch's styles, from the tree as it is (no parse).
        // (Not while one is on its way: it renders again when it lands, and asks then if need be.)
        if syntaxDocument != nil, !highlightPending, NSIntersectionRange(wanted, styled).length < wanted.length {
            scheduleHighlight(after: 0)
        }
        guard let whole = textView.textRange(wanted) else { return }
        layout.removeRenderingAttribute(.foregroundColor, for: whole)
        layout.removeRenderingAttribute(.backgroundColor, for: whole)
        let plain = Scheme.theme.foreground
        for (range, style) in styles {
            let part = NSIntersectionRange(range, wanted)
            guard part.length > 0, let text = textView.textRange(part) else { continue }
            if style.foreground != plain { layout.addRenderingAttribute(.foregroundColor, value: NSColor(style.foreground), for: text) }
            if let background = style.background { layout.addRenderingAttribute(.backgroundColor, value: NSColor(background), for: text) }
        }
        for block in textView.conflictBlocks {
            for marker in block.markers {
                let part = NSIntersectionRange(marker, wanted)
                if part.length > 0, let text = textView.textRange(part) { layout.addRenderingAttribute(.foregroundColor, value: NSColor.clear, for: text) }
            }
        }
        applyFaces(in: wanted)
        rendered = wanted
        textView.needsDisplay = true
    }

    /// The editor font's faces (HL5): the font's own bold and italic; slanted if it has no
    /// italic, and left regular if it has no bold (the system monospaced font has both).
    private var faces = Editor.faces(of: Scheme.font)

    private static func faces(of regular: NSFont) -> (regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont) {
        let manager = NSFontManager.shared
        func face(_ trait: NSFontTraitMask, from font: NSFont) -> NSFont {
            let converted = manager.convert(font, toHaveTrait: trait)
            if manager.traits(of: converted).contains(trait) { return converted }
            if trait == .italicFontMask {
                return NSFont(descriptor: font.fontDescriptor, textTransform: AffineTransform(m11: 1, m12: 0, m21: 0.21, m22: 1, tX: 0, tY: 0)) ?? font
            }
            return font
        }
        let bold = face(.boldFontMask, from: regular)
        return (regular, bold, face(.italicFontMask, from: regular), face(.italicFontMask, from: bold))
    }

    private func face(_ style: Style) -> NSFont {
        switch (style.bold, style.italic) {
        case (true, true): faces.boldItalic
        case (true, false): faces.bold
        case (false, true): faces.italic
        case (false, false): faces.regular
        }
    }

    /// Bold, italic and underline as attributes on the text storage, only where they differ from
    /// what's there. Attribute changes aren't edits: nothing is journaled, saved or undoable,
    /// and copying stays plain text.
    private func applyFaces(in wanted: NSRange) {
        guard let storage = textView.textStorage, wanted.length > 0, NSMaxRange(wanted) <= storage.length else { return }
        var desired: [(range: NSRange, font: NSFont, underline: Bool)] = []
        var at = wanted.location
        for (range, style) in styles where NSMaxRange(range) > wanted.location && range.location < NSMaxRange(wanted) {
            let part = NSIntersectionRange(range, wanted)
            guard part.length > 0, part.location >= at else { continue }
            if part.location > at { desired.append((NSRange(location: at, length: part.location - at), faces.regular, false)) }
            desired.append((part, face(style), style.underline))
            at = NSMaxRange(part)
        }
        if at < NSMaxRange(wanted) { desired.append((NSRange(location: at, length: NSMaxRange(wanted) - at), faces.regular, false)) }
        var changes: [(NSRange, NSFont?, Bool?)] = []
        for (range, font, underline) in desired {
            storage.enumerateAttributes(in: range) { attributes, part, _ in
                let fontDiffers = (attributes[.font] as? NSFont) != font
                let hasUnderline = (attributes[.underlineStyle] as? Int ?? 0) != 0
                if fontDiffers || hasUnderline != underline { changes.append((part, fontDiffers ? font : nil, hasUnderline != underline ? underline : nil)) }
            }
        }
        guard !changes.isEmpty else { return }
        storage.beginEditing()
        for (range, font, underline) in changes {
            if let font { storage.addAttribute(.font, value: font, range: range) }
            if let underline {
                if underline { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                else { storage.removeAttribute(.underlineStyle, range: range) }
            }
        }
        storage.endEditing()
    }

    /// Typing next to a bold or italic word doesn't carry its face on.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        [.font: Scheme.font, .foregroundColor: Scheme.foreground]
    }

    /// The characters TextKit 2 has in its viewport now.
    private func visibleRange() -> NSRange {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return NSRange(location: 0, length: 0) }
        // Just scrolled, the viewport isn't laid out yet and would still say where it was:
        // lay it out now (TextKit 2's own call; nothing touches `layoutManager`).
        layout.textViewportLayoutController.layoutViewport()
        guard let viewport = layout.textViewportLayoutController.viewportRange else { return NSRange(location: 0, length: 0) }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        return NSRange(location: start, length: content.offset(from: viewport.location, to: viewport.endLocation))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.needsDisplay = true   // the current-line highlight follows the caret
        if let document {
            let (line, column) = position(of: textView.selectedRange().location)
            document.selectionDidChange(line: line, column: column)
        }
        onSelection?()
    }

    // MARK: Conflict blocks: the keys (§5.4, §5.5)

    /// The block the caret is in, if any.
    func block(atCaretIn blocks: [ConflictBlock]) -> Int? {
        let caret = textView.selectedRange().location
        return blocks.firstIndex { caret >= $0.range.location && caret < NSMaxRange($0.range) }
    }

    /// ⌘1, ⌘2, ⌘3 on `block`: an edit like typing, one undo step. Returns whose version was kept.
    @discardableResult
    func resolve(_ block: ConflictBlock, _ choice: ConflictBlock.Choice) -> String {
        let kept = ConflictText.resolution(of: block, choice, in: textView.string)
        guard textView.shouldChangeText(in: block.range, replacementString: kept) else { return "" }
        textView.textStorage?.replaceCharacters(in: block.range, with: kept)
        textView.didChangeText()
        let label = choice == .first ? block.firstLabel : choice == .second ? block.secondLabel : "both"
        textView.undoManager?.setActionName(choice == .both ? "Keep Both" : "Use \(label)")
        textView.setSelectedRange(NSRange(location: block.range.location + (kept as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        return label
    }

    /// ⌥⌘↓ and ⌥⌘↑: the caret to the next (or previous) block's first version, round the end.
    func go(forward: Bool, in blocks: [ConflictBlock]) {
        guard !blocks.isEmpty else { NSSound.beep(); return }
        let caret = textView.selectedRange().location
        let target = forward
            ? blocks.first { $0.range.location > caret } ?? blocks[0]
            : blocks.last { NSMaxRange($0.range) <= caret } ?? blocks[blocks.count - 1]
        textView.setSelectedRange(NSRange(location: target.first.location, length: 0))
        textView.scrollRangeToVisible(target.range)
        textView.window?.makeFirstResponder(textView)
    }

    /// Line and column (1-based) of a UTF-16 offset, counting in chunks: a few ms at 2.4 MB.
    /// Line and column at a location (the strip's LN, COL), counted on from the last place
    /// asked: typing moves the caret a character at a time, and counting from the top was
    /// 255 ms a keystroke at the end of a 2.4 MB file (Debug). The count stays good through an
    /// edit that starts on its line or after it (`textStorage(_:didProcessEditing:…)`).
    func position(of location: Int) -> (Int, Int) {
        guard let storage = textView.textStorage else { return (1, 1) }
        let string = storage.string as NSString
        let target = min(location, string.length)
        var (at, line, lineStart) = lineCache.map { ($0.location, $0.line, $0.lineStart) } ?? (0, 1, 0)
        if at > string.length || target < lineStart { (at, line, lineStart) = (0, 1, 0) }   // before its line: from the top
        if target >= at {
            var buffer = [unichar](repeating: 0, count: 4_096)
            var offset = at
            while offset < target {
                let count = min(buffer.count, target - offset)
                string.getCharacters(&buffer, range: NSRange(location: offset, length: count))
                buffer.withUnsafeBufferPointer { units in
                    for i in 0..<count where units[i] == 0x0A { line += 1; lineStart = offset + i + 1 }
                }
                offset += count
            }
        }
        lineCache = (target, line, lineStart)
        return (line, target - lineStart + 1)
    }

    private var lineCache: (location: Int, line: Int, lineStart: Int)?
    /// The last change to the characters, in the text as it is now.
    private(set) var lastEdit: NSRange?

    /// Every change to the characters, typed or not (a merge, a reload): the line count up to
    /// an edit's start still holds if the edit starts on the counted line or after it.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            lastEdit = editedRange
            guard let cache = lineCache else { return }
            lineCache = editedRange.location >= cache.lineStart
                ? (min(cache.location, editedRange.location), cache.line, cache.lineStart)
                : nil
        }
    }

    // MARK: Caret per Mac (SC3): local, never synced

    func saveSelection(for url: URL) {
        let range = textView.selectedRange()
        UserDefaults.standard.set([range.location, range.length], forKey: "selection:" + url.path)
    }

    func restoreSelection(for url: URL) {
        guard let saved = UserDefaults.standard.array(forKey: "selection:" + url.path) as? [Int], saved.count == 2 else { return }
        let length = (textView.string as NSString).length
        let location = min(saved[0], length)
        textView.setSelectedRange(NSRange(location: location, length: min(saved[1], length - location)))
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

/// Plain text in, plain text out (PT1, PT2), and Sublime's current-line highlight.
final class NibTextView: NSTextView {
    /// Escape, before the text view's own use of it: true if it was handled (the banner hidden).
    var onEscape: (() -> Bool)?
    /// Conflict blocks, drawn as HUD frames behind the text (§5.4), and a VoiceOver rotor.
    var conflictBlocks: [ConflictBlock] = [] {
        didSet { if oldValue.isEmpty != conflictBlocks.isEmpty { NSAccessibility.post(element: self, notification: .layoutChanged) } }
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        super.cancelOperation(sender)
    }

    /// ⌘V: the clipboard's text only, line endings made "\n". Files copied in Finder
    /// paste as their paths, one per line.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        var text = pasteboard.string(forType: .string)
        if text == nil,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            text = urls.map(\.path).joined(separator: "\n")
        }
        guard let text else { NSSound.beep(); return }
        insertText(PasteCleaner.plain(text), replacementRange: selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    /// Copying never carries RTF or the colors on screen: plain text only.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        super.writeSelection(to: pboard, types: [.string])
    }

    /// Conflict blocks' panels, the caret's visual line in An Old Hope's line highlight
    /// (#272B34), then the blocks' frames over both, all under the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let frames = conflictBlocks.map { frameGeometry($0) }
        for frame in frames.compactMap({ $0 }) where frame.box.intersects(rect) {
            Scheme.conflictBlock.setFill()
            frame.box.intersection(rect).fill()
        }
        if selectedRange().length == 0, let line = currentLineRect() {
            Scheme.lineHighlight.setFill()
            line.intersection(rect).fill()
        }
        for (block, frame) in zip(conflictBlocks, frames) {
            if let frame, frame.box.insetBy(dx: 0, dy: -12).intersects(rect) { drawFrame(block, frame) }
        }
    }

    // MARK: Conflict frames (§5.4)

    /// ┌ AIR · 10:42 ──── ⌘1 USE · ⌘3 BOTH ┐ over the first marker, ├ MINI · 10:41 ── ⌘2 USE ┤
    /// over the second, └──┘ over the last; 1 pt lines in the one red, Silkscreen labels, and
    /// the pixel ✕ in the gutter (V3, V5, V6).
    private struct FrameGeometry {
        var top: NSRect, middle: NSRect, bottom: NSRect
        var left: CGFloat, right: CGFloat
        /// From the first marker line's middle to the last's: the panel inside the frame.
        var box: NSRect { NSRect(x: left, y: top.midY.rounded(), width: right - left, height: bottom.midY.rounded() - top.midY.rounded() + 1) }
    }

    private func frameGeometry(_ block: ConflictBlock) -> FrameGeometry? {
        guard block.markers.count == 3,
              let top = bandRect(NSRange(location: block.markers[0].location, length: 1)),
              let middle = bandRect(NSRange(location: block.markers[1].location, length: 1)),
              let bottom = bandRect(NSRange(location: block.markers[2].location, length: 1)) else { return nil }
        return FrameGeometry(top: top, middle: middle, bottom: bottom, left: 10, right: bounds.width - 10)
    }

    private func drawFrame(_ block: ConflictBlock, _ frame: FrameGeometry) {
        let (top, middle, bottom, left, right) = (frame.top, frame.middle, frame.bottom, frame.left, frame.right)
        let yTop = top.midY.rounded(), yMiddle = middle.midY.rounded(), yBottom = bottom.midY.rounded()
        Scheme.conflictBar.setFill()
        NSRect(x: left, y: yTop, width: right - left, height: 1).fill()
        NSRect(x: left, y: yMiddle, width: right - left, height: 1).fill()
        NSRect(x: left, y: yBottom, width: right - left, height: 1).fill()
        NSRect(x: left, y: yTop, width: 1, height: yBottom - yTop + 1).fill()
        NSRect(x: right - 1, y: yTop, width: 1, height: yBottom - yTop + 1).fill()
        drawLabel(block.firstLabel.uppercased(), hint: "⌘1 USE · ⌘3 BOTH", on: top, left: left, right: right)
        drawLabel(block.secondLabel.uppercased(), hint: "⌘2 USE", on: middle, left: left, right: right)
        drawCross(at: NSPoint(x: 1, y: (top.midY - 3.5).rounded()))
    }

    private static let labelFont = NSFont(name: "Silkscreen-Regular", size: 9) ?? .monospacedSystemFont(ofSize: 8, weight: .medium)

    /// A label and a hint on a frame line, each on a cut-out so the line stops short of them.
    private func drawLabel(_ label: String, hint: String, on line: NSRect, left: CGFloat, right: CGFloat) {
        func draw(_ text: String, color: NSColor, x: (CGFloat) -> CGFloat) {
            let string = NSAttributedString(string: " \(text) ", attributes: [.font: Self.labelFont, .foregroundColor: color])
            let size = string.size()
            let origin = NSPoint(x: x(size.width).rounded(), y: (line.midY - size.height / 2).rounded())
            let cut = NSRect(origin: origin, size: size)
            Scheme.background.setFill()
            NSRect(x: cut.minX, y: cut.minY, width: cut.width, height: line.midY.rounded() - cut.minY).fill()
            Scheme.conflictBlock.setFill()
            NSRect(x: cut.minX, y: line.midY.rounded(), width: cut.width, height: cut.maxY - line.midY.rounded()).fill()
            string.draw(at: origin)
        }
        draw(label, color: Scheme.conflictMarker) { _ in left + 10 }
        draw(hint, color: Scheme.comment) { width in right - 10 - width }
    }

    /// The pixel ✕ (Blit's 7×7 glyph, 1 pt a pixel) in the one red.
    private func drawCross(at origin: NSPoint) {
        Scheme.conflictBar.setFill()
        for (y, row) in PixelGlyph.cross.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                NSRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y), width: 1, height: 1).fill()
            }
        }
    }

    // MARK: VoiceOver: a Conflicts rotor (AX2)

    override func accessibilityCustomRotors() -> [NSAccessibilityCustomRotor] {
        let rotors = super.accessibilityCustomRotors()
        return conflictBlocks.isEmpty ? rotors : rotors + [NSAccessibilityCustomRotor(label: "Conflicts", itemSearchDelegate: self)]
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textLayoutManager?.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The full-width band a range's lines take up.
    private func bandRect(_ range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let textRange = textRange(range) else { return nil }
        var top = CGFloat.greatestFiniteMagnitude, bottom = -CGFloat.greatestFiniteMagnitude
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            top = min(top, frame.minY)
            bottom = max(bottom, frame.maxY)
            return true
        }
        guard top < bottom else { return nil }
        return NSRect(x: 0, y: textContainerOrigin.y + top, width: bounds.width, height: bottom - top)
    }

    private func currentLineRect() -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let caret = selectedRange().location
        let documentStart = content.documentRange.location
        guard let location = content.location(documentStart, offsetBy: caret) else { return nil }
        let origin = textContainerOrigin
        guard let fragment = layout.textLayoutFragment(for: location) else {
            // After a final newline there's no fragment yet: the empty last line.
            guard caret == (string as NSString).length, let last = layout.textLayoutFragment(for: content.documentRange.endLocation)
                    ?? lastFragment(layout) else { return nil }
            let frame = last.layoutFragmentFrame
            // TextKit 2 lays the empty last line out as the last paragraph's extra line, when it has.
            if last.textLineFragments.count > 1, let extra = last.textLineFragments.last, extra.characterRange.length == 0 {
                let bounds = extra.typographicBounds
                return NSRect(x: 0, y: origin.y + frame.minY + bounds.minY, width: self.bounds.width, height: bounds.height)
            }
            let height = Scheme.font.ascender - Scheme.font.descender + Scheme.font.leading
            return NSRect(x: 0, y: origin.y + frame.maxY, width: bounds.width, height: ceil(height))
        }
        let frame = fragment.layoutFragmentFrame
        let offsetInParagraph = content.offset(from: fragment.rangeInElement.location, to: location)
        for line in fragment.textLineFragments {
            let range = line.characterRange
            if offsetInParagraph >= range.location, offsetInParagraph < NSMaxRange(range) || line === fragment.textLineFragments.last {
                let bounds = line.typographicBounds
                return NSRect(x: 0, y: origin.y + frame.minY + bounds.minY, width: self.bounds.width, height: bounds.height)
            }
        }
        return NSRect(x: 0, y: origin.y + frame.minY, width: bounds.width, height: frame.height)
    }

    private func lastFragment(_ layout: NSTextLayoutManager) -> NSTextLayoutFragment? {
        var last: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse]) { fragment in
            last = fragment
            return false
        }
        return last
    }
}

/// VoiceOver's Conflicts rotor: each block, named by its two versions.
extension NibTextView: @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
    func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        let current = searchParameters.currentItem?.targetRange.location ?? selectedRange().location
        let block = searchParameters.searchDirection == .next
            ? conflictBlocks.first { $0.range.location > current || (searchParameters.currentItem == nil && NSLocationInRange(current, $0.range)) }
            : conflictBlocks.last { $0.range.location < current }
        guard let block else { return nil }
        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: self)
        result.targetRange = block.range
        result.customLabel = "Conflict: \(block.firstLabel), or \(block.secondLabel)"
        return result
    }
}

extension NSColor {
    convenience init(_ color: RGBA) {
        self.init(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }
}
