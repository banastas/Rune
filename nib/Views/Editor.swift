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
        textView.setAccessibilityLabel("Scratch")
        scrollView.documentView = textView
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

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

    /// The caret's visual line, in An Old Hope's line highlight (#272B34).
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let line = currentLineRect() else { return }
        OldHope.lineHighlight.setFill()
        line.intersection(rect).fill()
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
