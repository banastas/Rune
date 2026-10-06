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
    let scrollView: EditorScrollView
    let textView: NibTextView
    weak var document: Document?
    /// The editor's own undo history (ED1): it lives as long as the buffer, so closing and
    /// reopening the window keeps it. (Inside SwiftUI's window the text view had none.)
    let undo = UndoManager()
    /// Find and replace (ED7): its bar, its matches, drawn here in the scheme's find colors.
    let find = FindSession()

    /// The minimap beside the scroller (ED11), while it's on; never in the merge view's panes.
    private(set) var minimap: MinimapView?
    private let allowsMinimap: Bool

    init(minimap: Bool = true) {
        allowsMinimap = minimap
        scrollView = EditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Scheme.background
        scrollView.scrollerStyle = .overlay
        textView = NibTextView(usingTextLayoutManager: true)
        super.init()
        find.editor = self
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
        textView.usesFindBar = false   // Nib's own bar (ED7): the system's has no regular expressions
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
        textView.onEscape = { [weak self] in
            guard let self else { return false }
            if self.document?.hideBanner() == true { return true }
            if self.find.shown { self.find.close(); return true }
            return false
        }
        textView.finder = find
        textView.onNotice = { [weak self] in self?.document?.show($0, for: 6) }
        textView.onFlash = { [weak self] in self?.flash($0) }
        textView.onCarets = { [weak self] in
            self?.document?.caretCount = $0
            self?.ruler?.needsDisplay = true   // every caret's line number bright
        }
        textView.commentStyle = { [weak self] in self?.commentStyle }
        textView.setAccessibilityLabel("Scratch")
        textView.usesRuler = false   // the gutter is Nib's own ruler; the text view's ruler support stays out of it
        scrollView.documentView = textView
        applyDisplaySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDisplaySettings() }
        }
        // Scrolling brings new text into view: render it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.render()
                self?.ruler?.needsDisplay = true
                self?.minimap?.needsDisplay = true
                if self?.textView.multi == true { self?.textView.updateCaretViews() }   // placed for real once in view
            }
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
        minimap?.needsDisplay = true
    }

    /// For an editor with no document (the merge view's result): told of changes and caret moves.
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?

    func textDidChange(_ notification: Notification) {
        textView.matchedTags = []   // till the tree has the edit (`updateMatches`)
        document?.textDidChange()
        onChange?()
        scheduleHighlight()
        find.textChanged()
    }

    /// Several ranges at once (multiple carets, ED8), in order and apart. With this one there,
    /// NSTextView asks it for every change. The colors and Find's matches move in one pass over
    /// them all: one pass a range was 2.3 s of a keystroke at 2,000 carets (Debug).
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard affectedRanges.count > 1 else {
            return affectedRanges.first.map { self.textView(textView, shouldChangeTextIn: $0.rangeValue, replacementString: replacementStrings?.first) } ?? true
        }
        let ranges = affectedRanges.map(\.rangeValue)
        let inserted = ranges.indices.map { (replacementStrings?[$0] as NSString?)?.length ?? 0 }
        var before = [0]   // before[i]: how much the edits before the i-th changed the length
        for (range, length) in zip(ranges, inserted) { before.append(before[before.count - 1] + length - range.length) }
        /// How many edits end at or before `p` (an insertion at `p` among them).
        func passed(_ p: Int) -> Int {
            var low = 0, high = ranges.count
            while low < high {
                let mid = (low + high) / 2
                if NSMaxRange(ranges[mid]) <= p { low = mid + 1 } else { high = mid }
            }
            return low
        }
        /// Where `p` is after the edits: moved by those before it; inside one, a style's start
        /// goes after its new text and an end to its start (as one edit moves them, below).
        func moved(_ p: Int, start: Bool) -> Int {
            let i = passed(p)
            guard i < ranges.count, ranges[i].location < p else { return p + before[i] }
            return ranges[i].location + before[i] + (start ? inserted[i] : 0)
        }
        styles = styles.compactMap { item in
            let start = moved(item.range.location, start: true), end = moved(NSMaxRange(item.range), start: false)
            return end > start ? (NSRange(location: start, length: end - start), item.style) : nil
        }
        // Find's matches move too; one an edit touches is gone until the next search.
        if !findMatches.isEmpty {
            shownMatches = shownMatches.compactMap { r in
                let i = passed(r.location)
                guard i == ranges.count || ranges[i].location >= NSMaxRange(r) else { return nil }
                return NSRange(location: r.location + before[i], length: r.length)
            }
        }
        for (range, length) in zip(ranges, inserted).reversed() { find.textWillChange(in: range, change: length - range.length) }
        return true
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
            } else if end <= range.location {
                return item                                             // before it: as it was (it was stretched to the edit)
            } else if r.location < range.location {
                r.length = range.location - r.location                  // cut by it: what came before
            } else {
                r = NSRange(location: range.location + inserted, length: end - editEnd)   // its tail, after the new text
            }
            return r.length > 0 ? (r, style) : nil
        }
        // Find's matches move with the text too; one the edit touches is gone until the next search.
        if !findMatches.isEmpty {
            let editEnd = NSMaxRange(range)
            shownMatches = shownMatches.compactMap { r in
                if r.location >= editEnd { return NSRange(location: r.location + change, length: r.length) }
                return NSMaxRange(r) <= range.location ? r : nil
            }
        }
        find.textWillChange(in: range, change: change)
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
    private(set) var styles: [(range: NSRange, style: Style)] = []
    private var styled = NSRange(location: 0, length: 0)
    private var highlightTask: Task<Void, Never>?
    private var highlightPending = false
    private var edits = 0
    private var rendered = NSRange(location: 0, length: 0)

    /// Find's matches (ED7), in order: drawn in `render` while its bar is open.
    var findMatches: [NSRange] {
        get { shownMatches }
        set { shownMatches = newValue; render(force: true) }
    }
    private var shownMatches: [NSRange] = []

    /// The first of `ranges` (in order) that ends after `location`: a binary search, as there
    /// can be 10,000 of them.
    private static func firstEnding(after location: Int, in ranges: [NSRange]) -> Int {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(ranges[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A copied range, lit in the selection color for a moment (SC5), then its own colors again.
    func flash(_ range: NSRange) {
        guard let layout = textView.textLayoutManager, let text = textView.textRange(range) else { return }
        layout.addRenderingAttribute(.backgroundColor, value: Scheme.selection, for: text)
        redrawText()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let text = self.textView.textRange(NSIntersectionRange(range, NSRange(location: 0, length: (self.textView.string as NSString).length))) else { return }
            layout.removeRenderingAttribute(.backgroundColor, for: text)
            self.render(force: true)   // the scheme's own backgrounds back
        }
    }

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
        applyTabWidth()   // a font's space width sets it
        ruler?.fit()
        ruler?.needsDisplay = true
        minimap?.schemeChanged()
        rendered = NSRange(location: 0, length: 0)
        scheduleHighlight(after: 0)
        render(force: true)
        textView.needsDisplay = true
    }

    /// A moment after typing pauses, off the main thread: the tree brought up to the text (an
    /// incremental parse of the stretch around the view in a big file, `SyntaxDocument`), then
    /// the styles of the text in view and a margin. Up to 5 MB (ED9: larger files aren't
    /// highlighted).
    /// ED9: files up to 5 MB (5,000,000 characters) get every feature; above that, no highlighting.
    static let highlightLimit = 5_000_000

    func scheduleHighlight(after delay: Double = 0.08) {
        edits += 1
        highlightTask?.cancel()
        let version = edits
        guard let syntaxDocument, (textView.string as NSString).length <= Self.highlightLimit else {
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
            self.minimap?.needsDisplay = true
            self.updateMatches()   // the tree has the edits now: the tags round the caret
        }
    }

    /// The text in view, with 12,000 characters either side (`render` draws 3,000 either side),
    /// and what the minimap shows (ED11).
    private func styleWindow() -> NSRange {
        let view = visibleRange(), length = textView.textStorage?.length ?? 0
        var window = NSRange(location: max(0, view.location - 12_000), length: view.length + 24_000)
        if let shown = minimapWanted() { window = NSUnionRange(window, shown) }
        return NSIntersectionRange(window, NSRange(location: 0, length: length))
    }

    /// What the minimap shows, for its colors: at most 200,000 characters of it, round the view.
    private func minimapWanted() -> NSRange? {
        guard let minimap, !minimap.isHidden, let shown = minimap.shownRange(), shown.length > 0 else { return nil }
        guard shown.length > 200_000 else { return shown }
        let start = min(max(shown.location, visibleRange().location - 100_000), NSMaxRange(shown) - 200_000)
        return NSRange(location: start, length: 200_000)
    }

    /// The minimap drew what it shows: its colors too, if they aren't here (it draws again when
    /// they come). Asked once for a stretch, so a stretch that can't be styled isn't asked again.
    func minimapDrew() {
        guard syntaxDocument != nil, !highlightPending, let wanted = minimapWanted(),
              NSIntersectionRange(wanted, styled).length < wanted.length,
              minimapAsked.map({ NSIntersectionRange(wanted, $0).length < wanted.length }) ?? true else { return }
        minimapAsked = wanted
        scheduleHighlight(after: 0.15)
    }

    private var minimapAsked: NSRange?

    /// A stretch of text into view, by its start (`NibTextView.reveal`).
    func reveal(_ range: NSRange) { textView.reveal(range.location) }

    /// The row with `location` at the top of the view (the minimap's click and drag): laid out
    /// there first, which TextKit 2 does without laying out the text before it.
    func scroll(toTop location: Int) {
        textView.reveal(location, linesAbove: 0)
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
        // Find's matches in view (ED7), every one in the scheme's find colors, the current one
        // too, outlined (`NibTextView.currentMatch`). It showed as the selection, which AppKit
        // draws in its inactive grey while the bar has the focus, under the scheme's light text:
        // the color changed at every jump, and the current one was the hardest to read (the
        // user, 2026-10-06).
        if !shownMatches.isEmpty {
            let highlight = Scheme.findHighlight, foreground = Scheme.findHighlightForeground
            var i = Self.firstEnding(after: wanted.location, in: shownMatches)
            while i < shownMatches.count, shownMatches[i].location < NSMaxRange(wanted) {
                let match = shownMatches[i]
                i += 1
                guard let text = textView.textRange(NSIntersectionRange(match, wanted)) else { continue }
                layout.addRenderingAttribute(.backgroundColor, value: highlight, for: text)
                if let foreground { layout.addRenderingAttribute(.foregroundColor, value: foreground, for: text) }
            }
        }
        textView.placeCurrentMatch()
        for block in textView.conflictBlocks {
            for marker in block.markers {
                let part = NSIntersectionRange(marker, wanted)
                if part.length > 0, let text = textView.textRange(part) { layout.addRenderingAttribute(.foregroundColor, value: NSColor.clear, for: text) }
            }
        }
        applyFaces(in: wanted)
        rendered = wanted
        redrawText()
    }

    /// TextKit 2 draws each stretch of text in a view of its own, into a layer, and draws it again
    /// only when its text changes: neither the text view's `needsDisplay` nor a change of rendering
    /// attributes reaches it, and the view ignores its own `needsDisplay`. New colors alone left
    /// lines as they were last drawn (the user's numbered list, 2026-10-02: each line in the colors
    /// of when it was last typed on, the first all white). The layers of the views in view, drawn again.
    private func redrawText() {
        textView.needsDisplay = true
        for child in textView.subviews {
            for line in child.subviews {
                line.layer?.setNeedsDisplay()
                line.layer?.sublayers?.forEach { $0.setNeedsDisplay() }
            }
        }
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
        [.font: Scheme.font, .foregroundColor: Scheme.foreground, .paragraphStyle: tabStyle]
    }

    // MARK: Indentation (ED6)

    /// The file's indentation, found when it opens: tabs drawn that many spaces wide, Tab and
    /// Indent adding one unit.
    var indentation: Indentation = .tabs(width: 4) {
        didSet { textView.indentation = indentation; applyTabWidth() }
    }

    private var tabStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = CGFloat(indentation.width) * (" " as NSString).size(withAttributes: [.font: Scheme.font]).width
        return style
    }

    /// Tabs as wide as the indentation says (AppKit's default is 28 points), on the whole text:
    /// an attribute, not an edit.
    func applyTabWidth() {
        let style = tabStyle
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Toggle Comment's marks for the file's syntax, as Sublime's are; nil for plain text, JSON,
    /// diffs, CSV and logs. INI's, which Sublime doesn't color, is its usual `;`.
    var commentStyle: CommentStyle? {
        switch syntax?.language {
        case .javascript, .jsx, .typescript, .tsx, .go, .rust, .java, .c, .php, .swift: .line("//")
        case .shell, .python, .yaml, .toml, .makefile, .gitCommit, .gitIgnore, .gitAttributes, .gitConfig, .ruby: .line("#")
        case .ini: .line(";")
        case .lua, .sql: .line("--")
        case .rst: .line("..")
        case .css: .block("/*", "*/")
        case .html, .markdown, .markdownInline, .xml: .block("<!--", "-->")
        case .json, .diff, .csv, .tsv, .log, nil: nil
        }
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
        updateMatches()
        ruler?.needsDisplay = true     // and the gutter's bright number
        if !shownMatches.isEmpty {
            find.selectionChanged()
            render(force: true)        // the selected match shows as the selection, the one before as a match
        }
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
        textView.reveal(textView.selectedRange().location)
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
        reveal(target.range)
        textView.window?.makeFirstResponder(textView)
    }

    /// Line and column (1-based) at a UTF-16 offset: the strip's LN, COL, from the line index.
    /// (Counting from the top was 255 ms a keystroke at the end of a 2.4 MB file, Debug.)
    func position(of location: Int) -> (Int, Int) {
        let target = min(max(0, location), textView.textStorage?.length ?? 0)
        let line = lineIndex.line(at: target)
        return (line, target - (lineIndex.start(ofLine: line) ?? 0) + 1)
    }

    /// Where each line starts (ED6), kept current edit by edit: LN, COL and the gutter.
    private(set) var lineIndex = LineIndex()
    /// The last change to the characters, in the text as it is now.
    private(set) var lastEdit: NSRange?

    /// Every change to the characters, typed or not (a merge, a reload): the line index looks
    /// at the changed characters only (the storage's own string, not a copy of it).
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            textView.textChangedForCarets()   // Undo Selection's steps were for the text before
            minimap?.textChanged()
            minimapAsked = nil
            lastEdit = editedRange
            if let storage = textView.textStorage { lineIndex.update(storage.mutableString, edited: editedRange, delta: delta) }
            ruler?.needsDisplay = true
            // A wider gutter re-tiles the scroll view, which lays the text out: not while the
            // storage is mid-edit (TextKit 2 throws), but once it's done.
            guard !fitPending else { return }
            fitPending = true
            DispatchQueue.main.async { [weak self] in
                self?.fitPending = false
                self?.ruler?.fit()
            }
        }
    }

    private var fitPending = false

    // MARK: Line numbers and invisibles (ED6)

    /// The gutter, while line numbers are on.
    private(set) var ruler: LineNumberRuler?

    /// Settings › Editor and the View menu: line numbers and the minimap (on unless turned
    /// off), invisibles (off unless turned on), for every editor at once.
    func applyDisplaySettings() {
        let defaults = NibDefaults.store
        let numbers = defaults.object(forKey: "editorLineNumbers") == nil || defaults.bool(forKey: "editorLineNumbers")   // "NO" from the command line too
        let invisibles = defaults.bool(forKey: "editorInvisibles")
        let wantsMinimap = allowsMinimap && (defaults.object(forKey: "editorMinimap") == nil || defaults.bool(forKey: "editorMinimap"))
        if wantsMinimap != (minimap != nil) {
            minimap = wantsMinimap ? MinimapView(editor: self) : nil
            scrollView.minimap = minimap
        }
        if numbers != (ruler != nil && scrollView.rulersVisible) {
            if numbers {
                let gutter = ruler ?? LineNumberRuler(scrollView: scrollView, editor: self)
                ruler = gutter
                scrollView.verticalRulerView = gutter
                scrollView.hasVerticalRuler = true
                scrollView.rulersVisible = true
                gutter.fit()
            } else {
                scrollView.rulersVisible = false
                scrollView.hasVerticalRuler = false
                ruler = nil
            }
        }
        if textView.showsInvisibles != invisibles { textView.showsInvisibles = invisibles }
        // ED10, on unless turned off, as in Sublime. Closing pairs are off for the scenarios'
        // typing unless one turns them on: they type text as it's to end up.
        let guides = defaults.object(forKey: "editorIndentGuides") == nil || defaults.bool(forKey: "editorIndentGuides")
        let matches = defaults.object(forKey: "editorMatchBrackets") == nil || defaults.bool(forKey: "editorMatchBrackets")
        let pairs = defaults.object(forKey: "editorAutoPairs") == nil ? NibDefaults.scenario == nil : defaults.bool(forKey: "editorAutoPairs")
        if textView.showsIndentGuides != guides { textView.showsIndentGuides = guides }
        if textView.matchBrackets != matches { textView.matchBrackets = matches; updateMatches() }
        textView.autoPairs = pairs
    }

    /// ED10: the brackets at the caret, now; the HTML element round it, from the tree, a moment
    /// after (and again when the tree has caught up with an edit).
    func updateMatches() {
        tagTask?.cancel()
        let view = textView
        guard view.matchBrackets, !view.multi, view.selectedRange().length == 0, let storage = view.textStorage else {
            view.matchedBrackets = nil
            view.matchedTags = []
            return
        }
        let caret = view.selectedRange().location
        view.matchedBrackets = Brackets.match(in: storage.mutableString, caret: caret)
        guard syntax?.language == .html || syntax?.language == .xml, let syntaxDocument, !highlightPending else { view.matchedTags = []; return }
        tagTask = Task { [weak self] in
            let names = await syntaxDocument.enclosingTagNames(at: caret)
            guard !Task.isCancelled, let self, self.textView.selectedRange() == NSRange(location: caret, length: 0) else { return }
            self.textView.matchedTags = names
        }
    }

    private var tagTask: Task<Void, Never>?

    // MARK: Caret per Mac (SC3): local, never synced

    func saveSelection(for url: URL) {
        let range = textView.selectedRange()
        NibDefaults.store.set([range.location, range.length], forKey: "selection:" + url.path)
    }

    func restoreSelection(for url: URL) {
        guard let saved = NibDefaults.store.array(forKey: "selection:" + url.path) as? [Int], saved.count == 2 else { return }
        let length = (textView.string as NSString).length
        let location = min(saved[0], length)
        textView.setSelectedRange(NSRange(location: location, length: min(saved[1], length - location)))
        revealWhenShown(location)
    }

    /// At open the view may not have its size yet, and a scroll then has nothing to scroll: the
    /// caret's place comes into view once it has (Reveal.swift: AppKit used to finish the scroll
    /// after the first layout, keeping a range that was later rebuilt).
    private func revealWhenShown(_ location: Int, tries: Int = 40) {
        if textView.visibleRect.height > 0 { textView.reveal(location); return }
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.revealWhenShown(location, tries: tries - 1) }
    }
}

/// Plain text in, plain text out (PT1, PT2), and Sublime's current-line highlight.
final class NibTextView: NSTextView {
    /// Escape: true if it closed something (the conflict banner, then the find bar).
    var onEscape: (() -> Bool)?

    // Multiple carets (ED8, MultiCarets.swift): all of them while there are several, the text
    // view's own selection on the primary one; nil with one.
    var carets: Carets?
    /// While Nib sets the selection itself; any other change (a click, ⌘A, Go to Line) is one caret again.
    var settingCarets = 0
    var caretViews: [NSTextInsertionIndicator] = []
    /// ⌘D's text came from a caret's word: whole words only; the word it picked, when that left one selection.
    var wholeWordSearch = false
    var expandedWord: NSRange?
    var typingRun: CaretRun?
    /// The count, for the strip.
    var onCarets: ((Int) -> Void)?
    /// Undo Selection's steps (⌘U, ⇧⌘U): the carets before each change since the last edit.
    var caretHistory = CaretHistory()
    /// The characters changed, and the steps start over once the change is done (`textChangedForCarets`).
    var caretSettlePending = false
    /// While Undo Selection puts carets back, or the mouse is held: no step of their own.
    var restoringCarets = 0
    var trackingMouse = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if settingCarets == 0, carets != nil {
            carets = nil
            caretsChanged()
        }
        if !stillSelecting { noteCarets() }   // a drag's end, not each place on the way
    }

    override func doCommand(by selector: Selector) {
        if multi {
            if multiCaretCommand(selector) { return }
            collapseCarets()   // not one done at several carets: at the primary, as ever
        }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if multi {
            guard replacementRange.location == NSNotFound else { collapseCarets(); super.insertText(string, replacementRange: replacementRange); return }
            typeAtCarets((string as? NSAttributedString)?.string ?? string as? String ?? "")
            return
        }
        // A key typed (not a paste, not Nib's own insert): its pair closed, a selection wrapped,
        // or a closer that's already there stepped over (ED10, `AutoPairs`).
        if autoPairs, replacementRange.location == NSNotFound, !hasMarkedText(), let storage = textStorage,
           let action = AutoPairs.typing((string as? NSAttributedString)?.string ?? string as? String ?? "", in: storage.mutableString, selection: selectedRange()) {
            switch action {
            case .edit(let range, let text, let selection):
                super.insertText(text, replacementRange: range)
                setSelectedRange(selection)
            case .skip(let to):
                setSelectedRange(NSRange(location: to, length: 0))
            }
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Backspace between an empty pair takes both (ED10).
    override func deleteBackward(_ sender: Any?) {
        if autoPairs, !multi, !hasMarkedText(), selectedRange().length == 0, let storage = textStorage,
           let pair = AutoPairs.deleting(in: storage.mutableString, caret: selectedRange().location) {
            setSelectedRange(pair)
        }
        super.deleteBackward(sender)
    }

    /// An input method composing (marked text): at one caret.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if multi { collapseCarets() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == .command { commandClick(event); return }
        if flags == .option, event.clickCount == 1, columnDrag(event) { return }
        super.mouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        if copyAtCarets() { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard multi else { super.cut(sender); return }
        guard copyAtCarets() else { return }
        let (edits, after) = currentCarets.deleting { _ in nil }   // the selections; a bare caret takes nothing
        perform(edits, then: after, action: "Cut")
    }
    /// Show Invisibles (ED6): spaces as dots, tabs as arrows, in the scheme's `invisibles`.
    var showsInvisibles = false { didSet { needsDisplay = true } }
    /// ED10 (Settings › Editor, on as in Sublime): closing brackets and quotes as they're typed,
    /// underlining matching brackets and tags, indent guides.
    var autoPairs = true
    var matchBrackets = true { didSet { needsDisplay = true } }
    var showsIndentGuides = true { didSet { needsDisplay = true } }
    /// Find's current match (ED7): in the find color as every match is, and outlined above the
    /// text, so it stands out from the rest without its color changing as it moves.
    var currentMatch: NSRange? { didSet { if oldValue != currentMatch { placeCurrentMatch() } } }
    private var currentMatchView: MatchOutline?

    /// The outline round the current match, where it's laid out now (after a scroll or an edit).
    func placeCurrentMatch() {
        guard let range = currentMatch, let rect = matchRect(range) else { currentMatchView?.isHidden = true; return }
        let outline = currentMatchView ?? {
            let made = MatchOutline()
            addSubview(made)   // after TextKit 2's own views: above the text
            currentMatchView = made
            return made
        }()
        outline.color = Scheme.findHighlightForeground ?? Scheme.foreground
        outline.frame = rect.insetBy(dx: -1.5, dy: -1)
        outline.isHidden = false
    }

    /// Whether the outline is shown round `range`, for the `find` scenario.
    func outlined(_ range: NSRange) -> Bool {
        guard let view = currentMatchView, !view.isHidden, currentMatch == range, let rect = matchRect(range) else { return false }
        return view.frame.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    /// A match's box on its first row, as laid out now; nil if it isn't.
    func matchRect(_ range: NSRange) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager, NSMaxRange(range) <= (textStorage?.length ?? 0),
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let fragment = layout.textLayoutFragment(for: start) else { return nil }
        let origin = textContainerOrigin, frame = fragment.layoutFragmentFrame
        let within = content.offset(from: fragment.rangeInElement.location, to: start)
        guard let row = fragment.textLineFragments.first(where: { NSLocationInRange(within, $0.characterRange) }) else { return nil }
        let left = origin.x + frame.minX + row.typographicBounds.minX, top = origin.y + frame.minY + row.typographicBounds.minY
        let x0 = left + row.locationForCharacter(at: within).x
        let x1 = left + row.locationForCharacter(at: min(within + range.length, NSMaxRange(row.characterRange))).x
        return NSRect(x: x0, y: top, width: max(2, x1 - x0), height: row.typographicBounds.height)
    }

    /// What's underlined: the brackets at the caret, and the HTML element's tag names round it.
    var matchedBrackets: Brackets.Match? { didSet { if oldValue != matchedBrackets { needsDisplay = true } } }
    var matchedTags: [NSRange] = [] { didSet { if oldValue != matchedTags { needsDisplay = true } } }
    #if DEBUG
    /// Drawn last, for the `pairs` scenario.
    private(set) var guidesDrawn = 0
    private(set) var underlinesDrawn = 0
    #endif
    #if DEBUG
    /// Dots and arrows drawn last, for the `gutter` scenario.
    private(set) var invisiblesDrawn = (dots: 0, arrows: 0)
    #endif
    /// Conflict blocks, drawn as HUD frames behind the text (§5.4), and a VoiceOver rotor.
    var conflictBlocks: [ConflictBlock] = [] {
        didSet { if oldValue.isEmpty != conflictBlocks.isEmpty { NSAccessibility.post(element: self, notification: .layoutChanged) } }
    }

    /// Escape closes things and does nothing else, as in Sublime: not the text view's word
    /// completion list, which ⌥Escape still asks for. (Opened from a scenario, the list was
    /// followed by a crash in SwiftUI's next update, three times out of three.)
    override func cancelOperation(_ sender: Any?) {
        if multi { collapseCarets(); return }   // one caret again, first (Sublime)
        _ = onEscape?()
    }

    /// ⌘V: the clipboard's text only, line endings made "\n" (PT1): rich text or HTML with no
    /// plain flavor as its text, files copied in Finder as their paths, one per line (PT5).
    override func paste(_ sender: Any?) {
        guard let text = Clipboard.text() else { NSSound.beep(); return }
        if multi { pasteAtCarets(PasteCleaner.plain(text)); return }
        insertText(PasteCleaner.plain(text), replacementRange: selectedRange())
    }

    /// Paste Clean (⌥⇧⌘V, PT3): also invisible characters out, unusual spaces made plain,
    /// trailing whitespace trimmed, and, with the setting, quotes and dashes straightened.
    override func pasteAsPlainText(_ sender: Any?) {
        guard let text = Clipboard.text() else { NSSound.beep(); return }
        let result = PasteCleaner.clean(text, options: Clipboard.options)
        if multi { pasteAtCarets(result.text) } else { insertText(result.text, replacementRange: selectedRange()) }
        onNotice?((["PASTED CLEAN"] + (result.changed ? result.facts : ["NOTHING NEEDED CLEANING"])).joined(separator: " · "))
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    // MARK: Files dragged in (ED2)

    /// Files dragged onto a window open, each in its tab, as in Sublime; text dragged in (or
    /// moved inside the view) goes in as ever. To put a file's path in the text, copy the file
    /// in Finder and paste (PT5).
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.openFiles(Self.droppedFiles(sender)) || super.performDragOperation(sender)
    }

    /// Files (not folders) from another app's drag: Finder's, say.
    private static func droppedFiles(_ drag: NSDraggingInfo) -> [URL] {
        guard drag.draggingSource == nil else { return [] }
        return files(on: drag.draggingPasteboard)
    }

    static func files(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
    }

    /// Opens them (the M1 safety rule shows its refusal in the window, as for ⌘O). False if none.
    @discardableResult
    static func openFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        urls.forEach { AppDelegate.openFile($0) }
        return true
    }

    /// Copy Block (⇧⌘C, SC5): the fenced code block at the caret, without its fences, or else
    /// its paragraph; with a selection, the selection. It flashes once.
    @objc func copyBlock(_ sender: Any?) {
        let selection = selectedRange()
        let found: (range: NSRange, kind: TextBlocks.Kind)?
        if selection.length > 0 { found = (selection, .paragraph) } else { found = TextBlocks.block(at: selection.location, in: string) }
        guard let found else {
            NSSound.beep()
            onNotice?("NOTHING TO COPY HERE · NO CODE BLOCK OR PARAGRAPH AT THE CARET")
            return
        }
        let text = (string as NSString).substring(with: found.range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onFlash?(found.range)
        let lines = text.components(separatedBy: "\n").count
        let what = selection.length > 0 ? "THE SELECTION" : found.kind == .code ? "THE CODE BLOCK" : "THE PARAGRAPH"
        onNotice?("COPIED \(what) · \(lines) LINE\(lines == 1 ? "" : "S")")
    }

    /// A line for the strip, and a range to flash: the editor's.
    var onNotice: ((String) -> Void)?
    var onFlash: ((NSRange) -> Void)?

    // MARK: Find (ED7, KB1): Nib's own bar, for the menu's commands and the system's

    weak var finder: FindSession?

    @objc func showFind(_ sender: Any?) { finder?.open(replace: false) }
    @objc func showFindAndReplace(_ sender: Any?) { finder?.open(replace: true) }
    @objc func findNextMatch(_ sender: Any?) { finder?.next() }
    @objc func findPreviousMatch(_ sender: Any?) { finder?.next(backwards: true) }
    @objc func useSelectionForFind(_ sender: Any?) { finder?.useSelection() }

    /// The system's find actions (a Services menu, an older Find menu), sent to Nib's bar.
    override func performTextFinderAction(_ sender: Any?) { performFindPanelAction(sender) }
    override func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        switch NSTextFinder.Action(rawValue: tag) {
        case .showReplaceInterface: finder?.open(replace: true)
        case .nextMatch: finder?.next()
        case .previousMatch: finder?.next(backwards: true)
        case .setSearchString: finder?.useSelection()
        case .hideFindInterface: finder?.close()
        default: finder?.open(replace: false)
        }
    }

    // MARK: Line commands (ED6, KB4, §5.12), on Sublime's keys

    var indentation: Indentation = .tabs(width: 4)
    var commentStyle: () -> CommentStyle? = { nil }

    /// One undoable change, named for the menu's Undo; the selection after it, in view.
    private func apply(_ edit: LineEdit?, _ action: String) {
        guard let edit else { NSSound.beep(); return }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        undoManager?.setActionName(action)
        setSelectedRange(edit.selection)
        reveal(edit.selection.location)
    }

    /// A line command at the caret, or at every caret (ED8): `make` given the text and a selection.
    private func lineCommand(_ action: String, groups: Carets.LineGroups = .sameLines, _ make: (String, NSRange) -> LineEdit?) {
        let text = string
        if multi { lineCommandAtCarets(action, groups: groups) { make(text, $0) } } else { apply(make(text, selectedRange()), action) }
    }

    @objc func duplicateLine(_ sender: Any?) { lineCommand("Duplicate Line") { LineEdits.duplicate($0, selection: $1) } }
    @objc func moveLineUp(_ sender: Any?) { lineCommand("Move Line Up", groups: .block) { LineEdits.move($0, selection: $1, up: true) } }
    @objc func moveLineDown(_ sender: Any?) { lineCommand("Move Line Down", groups: .block) { LineEdits.move($0, selection: $1, up: false) } }
    @objc func joinLines(_ sender: Any?) { lineCommand("Join Lines", groups: .joins) { LineEdits.join($0, selection: $1) } }
    @objc func indentLines(_ sender: Any?) {
        let indentation = indentation
        lineCommand("Indent") { LineEdits.indent($0, selection: $1, unit: indentation.unit, width: indentation.width) }
    }
    @objc func outdentLines(_ sender: Any?) {
        let indentation = indentation
        lineCommand("Outdent") { LineEdits.indent($0, selection: $1, unit: indentation.unit, outdent: true, width: indentation.width) }
    }
    @objc func selectWholeLine(_ sender: Any?) {
        let text = string
        if multi {
            let carets = currentCarets
            setCarets(Carets(carets.all.map { Caret(range: LineEdits.selectLine(text, selection: $0.range)) }, primary: carets.primary))
            return
        }
        let range = LineEdits.selectLine(text, selection: selectedRange())
        setSelectedRange(range)
        reveal(range.location)
    }
    @objc func toggleComment(_ sender: Any?) {
        guard let style = commentStyle() else {
            NSSound.beep()
            onNotice?("NO COMMENTS IN THIS SYNTAX · PICK ONE FROM THE STRIP")
            return
        }
        lineCommand("Toggle Comment") { LineEdits.toggleComment($0, selection: $1, style: style) }
    }

    /// Return keeps the line's indentation (Sublime's auto-indent).
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        let s = string as NSString, caret = selectedRange().location
        let line = s.lineRange(for: NSRange(location: caret, length: 0))
        let before = s.substring(with: NSRange(location: line.location, length: caret - line.location))
        let lead = before.prefix { $0 == " " || $0 == "\t" }
        // Between brackets: a line between, a step further in, the closer under the opener's line (ED10).
        if autoPairs, selectedRange().length == 0, let storage = textStorage,
           let made = AutoPairs.newline(in: storage.mutableString, caret: caret, indent: String(lead), unit: indentation.unit) {
            insertText(made.text, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: caret + made.caret, length: 0))
            return
        }
        insertText("\n" + lead, replacementRange: selectedRange())
    }

    /// Tab: over several lines, Indent; else one unit (spaces to the next stop).
    override func insertTab(_ sender: Any?) {
        let selection = selectedRange(), s = string as NSString
        if selection.length > 0, s.substring(with: selection).contains("\n") { indentLines(sender); return }
        guard case .spaces(let width) = indentation else { super.insertTab(sender); return }
        let line = s.lineRange(for: NSRange(location: selection.location, length: 0))
        let column = selection.location - line.location
        insertText(String(repeating: " ", count: width - column % width), replacementRange: selection)
    }

    /// ⇧Tab: Outdent.
    override func insertBacktab(_ sender: Any?) { outdentLines(sender) }

    /// Copying never carries RTF or the colors on screen: plain text only.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        super.writeSelection(to: pboard, types: [.string])
    }

    /// Conflict blocks' panels, the caret's visual line in An Old Hope's line highlight
    /// (#272B34; with several carets, each one's), then the blocks' frames over both, all
    /// under the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        #if DEBUG
        guidesDrawn = 0
        underlinesDrawn = 0
        #endif
        let frames = conflictBlocks.map { frameGeometry($0) }
        for frame in frames.compactMap({ $0 }) where frame.box.intersects(rect) {
            Scheme.conflictBlock.setFill()
            frame.box.intersection(rect).fill()
        }
        Scheme.lineHighlight.setFill()
        for caret in highlightedCarets() {
            if let line = lineRect(at: caret), line.intersects(rect) { line.intersection(rect).fill() }
        }
        drawOtherSelections(in: rect)
        for (block, frame) in zip(conflictBlocks, frames) {
            if let frame, frame.box.insetBy(dx: 0, dy: -12).intersects(rect) { drawFrame(block, frame) }
        }
        if showsInvisibles { drawInvisibles(in: rect) }
        if showsIndentGuides { drawIndentGuides(in: rect) }
        if matchBrackets { drawMatches(in: rect) }
    }

    // MARK: Indent guides and matching brackets (ED10)

    /// A guide at each step of a line's indentation, on its first row, dotted, as Sublime draws
    /// them by default (its "solid" option off); a blank line takes the guides of the lines round
    /// it, the fewer.
    private func drawIndentGuides(in rect: NSRect) {
        guard let layout = textLayoutManager, let content = layout.textContentManager, let storage = textStorage else { return }
        let text = storage.mutableString, origin = textContainerOrigin
        let space = (" " as NSString).size(withAttributes: [.font: font ?? Scheme.font]).width
        let tab = max(1, indentation.width)
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))
                ?? layout.textLayoutFragment(for: content.documentRange.location) else { return }
        Scheme.guide.setFill()
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard origin.y + frame.minY <= rect.maxY else { return false }
            guard let row = fragment.textLineFragments.first else { return true }
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let steps = (Self.indentColumns(text, line: start, tab: tab) + tab - 1) / tab
            guard steps > 0 else { return true }
            let left = origin.x + frame.minX + row.typographicBounds.minX + row.locationForCharacter(at: row.characterRange.location).x
            let top = (origin.y + frame.minY + row.typographicBounds.minY).rounded(.down)
            let bottom = origin.y + frame.minY + row.typographicBounds.maxY
            for step in 0..<steps {
                let x = (left + CGFloat(step * tab) * space).rounded(.down)
                var y = top
                while y < bottom { NSRect(x: x, y: y, width: 1, height: 1).fill(); y += 2 }
                #if DEBUG
                guidesDrawn += 1
                #endif
            }
            return true
        }
    }

    /// A line's indentation in columns (a tab to the next stop); a blank line's, the fewer of the
    /// non-blank lines round it (a hundred lines either way at most).
    private static func indentColumns(_ text: NSString, line start: Int, tab: Int) -> Int {
        func measure(_ at: Int) -> Int? {   // nil for a blank line
            var columns = 0, i = at
            while i < text.length {
                let c = text.character(at: i)
                if c == 0x20 { columns += 1 } else if c == 0x09 { columns = (columns / tab + 1) * tab } else { return c == 0x0A ? nil : columns }
                i += 1
            }
            return nil
        }
        if let columns = measure(start) { return columns }
        var before: Int?, after: Int?, at = start, steps = 0
        while before == nil, at > 0, steps < 100 {
            at = text.lineRange(for: NSRange(location: at - 1, length: 0)).location
            before = measure(at)
            steps += 1
        }
        at = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
        steps = 0
        while after == nil, at < text.length, steps < 100 {
            after = measure(at)
            at = NSMaxRange(text.lineRange(for: NSRange(location: at, length: 0)))
            steps += 1
        }
        return min(before ?? 0, after ?? 0)
    }

    /// The brackets at the caret, underlined as the scheme says (`brackets_*` beside it,
    /// `bracket_contents_*` round it), and the HTML element's tag names, stippled.
    private func drawMatches(in rect: NSRect) {
        if let match = matchedBrackets {
            let color = match.beside ? Scheme.bracketsForeground : Scheme.bracketContentsForeground
            let stippled = Scheme.stippled(match.beside ? "brackets_options" : "bracket_contents_options", else: false)
            for offset in [match.open, match.close] { underline(NSRange(location: offset, length: 1), color: color, stippled: stippled, in: rect) }
        }
        for name in matchedTags { underline(name, color: Scheme.tagsForeground, stippled: Scheme.stippled("tags_options", else: true), in: rect) }
    }

    private func underline(_ range: NSRange, color: NSColor, stippled: Bool, in rect: NSRect) {
        guard let layout = textLayoutManager, let content = layout.textContentManager, NSMaxRange(range) <= (textStorage?.length ?? 0),
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let fragment = layout.textLayoutFragment(for: start) else { return }
        let origin = textContainerOrigin, frame = fragment.layoutFragmentFrame
        let within = content.offset(from: fragment.rangeInElement.location, to: start)
        guard let row = fragment.textLineFragments.first(where: { NSLocationInRange(within, $0.characterRange) }) else { return }
        let rowOrigin = NSPoint(x: origin.x + frame.minX + row.typographicBounds.minX, y: origin.y + frame.minY + row.typographicBounds.minY)
        let x0 = rowOrigin.x + row.locationForCharacter(at: within).x
        let x1 = rowOrigin.x + row.locationForCharacter(at: min(within + range.length, NSMaxRange(row.characterRange))).x
        let line = NSRect(x: x0.rounded(.down), y: (rowOrigin.y + row.glyphOrigin.y + 2).rounded(), width: max(1, (x1 - x0).rounded()), height: 1)
        guard line.intersects(rect) else { return }
        color.setFill()
        if stippled {
            var x = line.minX
            while x < line.maxX { NSRect(x: x, y: line.minY, width: 1, height: 1).fill(); x += 2 }
        } else {
            line.fill()
        }
        #if DEBUG
        underlinesDrawn += 1
        #endif
    }

    /// Spaces (and no-break spaces) as a dot at the middle of the space, a tab as an arrow
    /// across it, under the text, for the lines in `rect`: each row's own character positions
    /// (TextKit 2's line fragments), so wrapped lines and wide tabs come out right.
    private func drawInvisibles(in rect: NSRect) {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let origin = textContainerOrigin
        let font = self.font ?? Scheme.font
        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, rect.minY - origin.y)))
                ?? layout.textLayoutFragment(for: content.documentRange.location) else { return }
        Scheme.invisibles.set()
        let dot = max(1.5, (font.pointSize / 9).rounded())
        #if DEBUG
        invisiblesDrawn = (0, 0)
        #endif
        layout.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard origin.y + frame.minY <= rect.maxY else { return false }
            for row in fragment.textLineFragments {
                let text = row.attributedString.string as NSString
                let range = row.characterRange
                guard range.length > 0, NSMaxRange(range) <= text.length else { continue }
                let rowOrigin = NSPoint(x: origin.x + frame.minX + row.typographicBounds.minX, y: origin.y + frame.minY + row.typographicBounds.minY)
                let middle = rowOrigin.y + row.glyphOrigin.y - font.xHeight / 2
                for i in range.location..<NSMaxRange(range) {
                    let c = text.character(at: i)
                    guard c == 0x20 || c == 0x09 || c == 0xA0 else { continue }
                    let x0 = rowOrigin.x + row.locationForCharacter(at: i).x
                    let x1 = rowOrigin.x + row.locationForCharacter(at: i + 1).x
                    #if DEBUG
                    if c == 0x09 { invisiblesDrawn.arrows += 1 } else { invisiblesDrawn.dots += 1 }
                    #endif
                    if c == 0x09 {
                        let path = NSBezierPath()
                        path.lineWidth = 1
                        path.move(to: NSPoint(x: x0 + 2, y: middle))
                        path.line(to: NSPoint(x: max(x0 + 4, x1 - 3), y: middle))
                        path.move(to: NSPoint(x: max(x0 + 4, x1 - 3) - 3, y: middle - 3))
                        path.line(to: NSPoint(x: max(x0 + 4, x1 - 3), y: middle))
                        path.line(to: NSPoint(x: max(x0 + 4, x1 - 3) - 3, y: middle + 3))
                        path.stroke()
                    } else {
                        NSBezierPath(ovalIn: NSRect(x: (x0 + x1) / 2 - dot / 2, y: middle - dot / 2, width: dot, height: dot)).fill()
                    }
                }
            }
            return true
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

    /// nil for a range that isn't all in the text: TextKit 2 takes an offset past the end without
    /// a word, and what it does with one is undefined (stale conflict frames crashed Nib).
    func textRange(_ range: NSRange) -> NSTextRange? {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= (string as NSString).length,
              let content = textLayoutManager?.textContentManager,
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

    /// The carets whose lines are highlighted: an empty one's, the primary's alone with one
    /// caret; with several, every empty one in the viewport.
    private func highlightedCarets() -> [Int] {
        guard let carets, carets.count > 1 else { return selectedRange().length == 0 ? [selectedRange().location] : [] }
        let span = viewportSpan()
        return carets.all.filter { $0.isEmpty && span.contains($0.head) }.map(\.head)
    }

    private func lineRect(at caret: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
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
        // "Air · 10:42" read as "Air, 10:42", not with the dot.
        func said(_ label: String) -> String { label.replacingOccurrences(of: " · ", with: ", ") }
        result.customLabel = "Conflict: \(said(block.firstLabel)), or \(said(block.secondLabel))"
        return result
    }
}

extension NSColor {
    convenience init(_ color: RGBA) {
        self.init(srgbRed: color.r, green: color.g, blue: color.b, alpha: color.a)
    }
}

/// Find's current match outlined (ED7): a view above the text, drawing its own rounded box, so
/// it shows over the find color, and in a picture of the window (which a layer's border isn't).
/// Clicks go through it to the text.
final class MatchOutline: NSView {
    var color = NSColor.black { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setStroke()
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
        box.lineWidth = 1.5
        box.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
