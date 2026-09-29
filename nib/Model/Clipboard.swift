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

    /// Paste Clean's options, from Settings › Editor.
    static var options: PasteCleaner.Options {
        .init(straightenQuotes: UserDefaults.standard.bool(forKey: "pasteStraightensQuotes"))
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
        if facts.isEmpty { facts = ["ALREADY PLAIN AND CLEAN"] }
        return (["CLIPBOARD CLEANED"] + facts).joined(separator: " · ")
    }

    /// Append Clipboard to Scratch (SC6): the cleaned clipboard at the end of scratch.md,
    /// after a blank line, without bringing Nib forward. One edit (⌘Z undoes it); the caret
    /// stays where it was.
    @discardableResult
    static func appendToScratch() -> String {
        let document = Documents.scratch
        guard document.ready, document.locked == nil else { return "COULDN'T APPEND · THE SCRATCH FILE ISN'T OPEN" }
        guard let text = text() else { return "THE CLIPBOARD HAS NO TEXT · NOTHING APPENDED" }
        var clean = PasteCleaner.clean(text, options: options).text
        while clean.hasSuffix("\n") { clean.removeLast() }
        guard !clean.isEmpty else { return "THE CLIPBOARD HAS NO TEXT · NOTHING APPENDED" }
        let view = document.editor.textView
        let current = view.string as NSString
        let lead = current.length == 0 ? "" : current.hasSuffix("\n\n") ? "" : current.hasSuffix("\n") ? "\n" : "\n\n"
        let addition = lead + clean + "\n"
        let end = NSRange(location: current.length, length: 0)
        let selection = view.selectedRange()
        guard view.shouldChangeText(in: end, replacementString: addition) else { return "COULDN'T APPEND · THE SCRATCH FILE IS READ-ONLY" }
        view.textStorage?.replaceCharacters(in: end, with: addition)
        view.didChangeText()
        view.undoManager?.setActionName("Append Clipboard")
        view.setSelectedRange(selection)
        let lines = clean.components(separatedBy: "\n").count
        let message = "APPENDED \(lines) LINE\(lines == 1 ? "" : "S") TO SCRATCH"
        document.show(message, for: 6)
        return message
    }
}
