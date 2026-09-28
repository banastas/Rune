// The text view (PRD ED1, §6.3): NSTextView on TextKit 2, plain text only, in An
// Old Hope's colors. One instance lives as long as the document, so closing and
// reopening the window keeps the buffer, the undo stack and the selection.
// Nothing here touches `layoutManager`, which would silently switch it to TextKit 1.

import AppKit
import NibText

@MainActor
final class Editor: NSObject, NSTextViewDelegate {
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
        scrollView.backgroundColor = OldHope.background
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
        textView.font = OldHope.font
        textView.textColor = OldHope.foreground
        textView.backgroundColor = OldHope.background
        textView.insertionPointColor = OldHope.caret
        textView.selectedTextAttributes = [.backgroundColor: OldHope.selection]
        textView.typingAttributes = [.font: OldHope.font, .foregroundColor: OldHope.foreground]
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.document?.hideBanner() ?? false }
        textView.setAccessibilityLabel("Scratch")
        scrollView.documentView = textView
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    private var highlighted: [ConflictBlock] = []

    /// Conflict blocks (§5.4): the text view draws each as a HUD frame on a panel, and the
    /// marker lines' own text is hidden under it with a TextKit 2 rendering attribute, so the
    /// file keeps plain markers that any editor can read.
    func highlight(_ blocks: [ConflictBlock]) {
        guard !(blocks.isEmpty && highlighted.isEmpty), let layout = textView.textLayoutManager else { return }
        highlighted = blocks
        textView.conflictBlocks = blocks
        layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
        for block in blocks {
            for marker in block.markers {
                if let range = textView.textRange(marker) { layout.addRenderingAttribute(.foregroundColor, value: NSColor.clear, for: range) }
            }
        }
        textView.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        document?.textDidChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.needsDisplay = true   // the current-line highlight follows the caret
        let (line, column) = position(of: textView.selectedRange().location)
        document?.selectionDidChange(line: line, column: column)
    }

    /// Line and column (1-based) of a UTF-16 offset, counting in chunks: a few ms at 2.4 MB.
    func position(of location: Int) -> (Int, Int) {
        guard let storage = textView.textStorage else { return (1, 1) }
        let string = storage.string as NSString
        let end = min(location, string.length)
        var line = 1
        var lastBreak = -1
        var buffer = [unichar](repeating: 0, count: 65_536)
        var offset = 0
        while offset < end {
            let count = min(buffer.count, end - offset)
            string.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count where buffer[i] == 0x0A {
                line += 1
                lastBreak = offset + i
            }
            offset += count
        }
        return (line, end - lastBreak)
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
            OldHope.conflictBlock.setFill()
            frame.box.intersection(rect).fill()
        }
        if selectedRange().length == 0, let line = currentLineRect() {
            OldHope.lineHighlight.setFill()
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
        OldHope.conflictBar.setFill()
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
            OldHope.background.setFill()
            NSRect(x: cut.minX, y: cut.minY, width: cut.width, height: line.midY.rounded() - cut.minY).fill()
            OldHope.conflictBlock.setFill()
            NSRect(x: cut.minX, y: line.midY.rounded(), width: cut.width, height: cut.maxY - line.midY.rounded()).fill()
            string.draw(at: origin)
        }
        draw(label, color: OldHope.conflictMarker) { _ in left + 10 }
        draw(hint, color: OldHope.comment) { width in right - 10 - width }
    }

    /// The pixel ✕ (Blit's 7×7 glyph, 1 pt a pixel) in the one red.
    private func drawCross(at origin: NSPoint) {
        OldHope.conflictBar.setFill()
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
            let height = OldHope.font.ascender - OldHope.font.descender + OldHope.font.leading
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
