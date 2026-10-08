// The clipboard (PRD PT1, PT3-PT5, SC6): its text however it came (plain; rich text or HTML
// only; files copied in Finder, as their paths, one per line), Clean Clipboard, which puts
// it back as clean plain text for any app, and Append Clipboard to Scratch.

import AppKit
import NibText

@MainActor
enum Clipboard {
    /// The clipboard's text, or nil if it has none (an image, say).
    static func text(_ pasteboard: NSPasteboard = .general) -> String? {
        if let plain = pasteboard.string(forType: .string) { return plain }
        // No plain flavor: rich text or HTML, as text (PT5).
        let rich: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [(.rtfd, .rtfd), (.rtf, .rtf), (.html, .html)]
        for (type, kind) in rich {
            guard let data = pasteboard.data(forType: type),
                  let attributed = try? NSAttributedString(data: data, options: [.documentType: kind, .characterEncoding: String.Encoding.utf8.rawValue],
                                                           documentAttributes: nil) else { continue }
            return attributed.string
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(\.path).joined(separator: "\n")
        }
        return nil
    }

    /// Paste Clean's options, from Settings › General.
    static var options: PasteCleaner.Options {
        .init(straightenQuotes: NibDefaults.store.bool(forKey: "pasteStraightensQuotes"))
    }

    /// Clean Clipboard (PT4): the clipboard rewritten in place as clean plain text, and what
    /// was done, for the confirmation ("CLIPBOARD CLEANED · 3 INVISIBLES REMOVED").
    @discardableResult
    static func cleanInPlace(_ pasteboard: NSPasteboard = .general) -> String {
        guard let text = text(pasteboard) else { return "THE CLIPBOARD HAS NO TEXT · NOTHING CHANGED" }
        let formatted = pasteboard.types?.contains { [.rtf, .rtfd, .html, .fileURL].contains($0) } ?? false
        let result = PasteCleaner.clean(text, options: options)
        pasteboard.clearContents()
        pasteboard.setString(result.text, forType: .string)
        var facts = result.changed ? result.facts : []
        if formatted { facts.append("FORMATTING DROPPED") }
        // Not "cleaned" when nothing needed it (F67: "CLIPBOARD CLEANED · ALREADY PLAIN AND CLEAN").
        if facts.isEmpty { return "THE CLIPBOARD WAS ALREADY PLAIN AND CLEAN · NOTHING CHANGED" }
        return (["CLIPBOARD CLEANED"] + facts).joined(separator: " · ")
    }

    /// Append Clipboard to Scratch (SC6): the cleaned clipboard at the end of scratch.md,
    /// after a blank line, without bringing Nib forward. One edit (⌘Z undoes it); the caret
    /// stays where it was.
    @discardableResult
    static func appendToScratch() -> String {
        guard Documents.scratch.ready else { return Appended.notOpen.hud }
        return append(text() ?? "", action: "Append Clipboard", from: "THE CLIPBOARD").hud
    }

    enum Appended: Equatable {
        /// Nothing left once cleaned, said of where the text came from: "the clipboard has no
        /// text" was said for the Service's selection, a Shortcut's text and `nib -a` too (F19).
        case lines(Int), notOpen, empty(from: String), readOnly

        /// For the strip, the menu bar panel and the HUD line.
        var hud: String {
            switch self {
            case .lines(let n): "APPENDED \(n) LINE\(n == 1 ? "" : "S") TO SCRATCH"
            case .notOpen: "✕ COULDN'T APPEND · THE SCRATCH FILE ISN'T OPEN"
            case .empty(let source): source == "THE CLIPBOARD" ? "NOTHING TO APPEND · THE CLIPBOARD HAS NO TEXT"
                                                                : "NOTHING TO APPEND · \(source) IS EMPTY ONCE CLEANED"
            case .readOnly: "✕ COULDN'T APPEND · THE SCRATCH FILE IS READ-ONLY"
            }
        }
    }

    /// Text at the end of the scratch file, cleaned as Paste Clean cleans it: the clipboard's
    /// (SC6), or standard input's (`cmd | nib -a`, AP4).
    static func append(_ text: String, action: String, from source: String) -> Appended {
        let document = Documents.scratch
        guard document.ready, document.locked == nil else { return .notOpen }
        var clean = PasteCleaner.clean(text, options: options).text
        while clean.hasSuffix("\n") { clean.removeLast() }
        guard !clean.isEmpty else { return .empty(from: source) }
        let view = document.editor.textView
        let current = view.string as NSString
        let lead = current.length == 0 ? "" : current.hasSuffix("\n\n") ? "" : current.hasSuffix("\n") ? "\n" : "\n\n"
        let addition = lead + clean + "\n"
        let end = NSRange(location: current.length, length: 0)
        let selection = view.selectedRange()
        guard view.shouldChangeText(in: end, replacementString: addition) else { return .readOnly }
        view.textStorage?.replaceCharacters(in: end, with: addition)
        view.didChangeText()
        view.undoManager?.setActionName(action)
        view.setSelectedRange(selection)
        let appended = Appended.lines(clean.components(separatedBy: "\n").count)
        document.show(appended.hud, for: 6)
        return appended
    }
}
