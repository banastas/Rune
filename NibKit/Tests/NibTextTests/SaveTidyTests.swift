// Tidying on ⌘S (ED6): trailing spaces and tabs trimmed, a final newline added, each only
// when asked, the text around them untouched, the caret carried through.

import Foundation
import Testing

@testable import NibText

@Suite struct SaveTidyTests {
    func applied(_ text: String, _ result: SaveTidy.Result) -> String {
        guard let edit = result.edit else { return text }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func trimsAndEnds() {
        let text = "one  \n\ttwo\t\n  \nthree \t"
        let both = SaveTidy.tidy(text, selection: NSRange(location: 0, length: 0), trimTrailing: true, finalNewline: true)
        #expect(applied(text, both) == "one\n\ttwo\n\nthree\n" && both.trimmedLines == 4 && both.addedNewline)
        let trim = SaveTidy.tidy(text, selection: NSRange(location: 0, length: 0), trimTrailing: true, finalNewline: false)
        #expect(applied(text, trim) == "one\n\ttwo\n\nthree" && !trim.addedNewline)
        let end = SaveTidy.tidy(text, selection: NSRange(location: 0, length: 0), trimTrailing: false, finalNewline: true)
        #expect(applied(text, end) == text + "\n" && end.trimmedLines == 0)   // spaces left as they are
        #expect(SaveTidy.tidy("", selection: NSRange(location: 0, length: 0), trimTrailing: true, finalNewline: true).edit == nil)
        #expect(SaveTidy.tidy("tidy\n", selection: NSRange(location: 0, length: 0), trimTrailing: true, finalNewline: true).edit == nil)
        #expect(SaveTidy.tidy("   ", selection: NSRange(location: 3, length: 0), trimTrailing: true, finalNewline: true).addedNewline == false)   // nothing left to end
    }

    @Test func caretCarriedThrough() {
        let text = "a  \nb c  \nd"
        // The caret after "b c" plus one trailing space: it ends after "b c".
        let r = SaveTidy.tidy(text, selection: NSRange(location: 8, length: 0), trimTrailing: true, finalNewline: true)
        let tidied = applied(text, r)
        #expect(tidied == "a\nb c\nd\n")
        #expect((tidied as NSString).substring(to: r.edit!.selection.location) == "a\nb c")
        // A selection of "d" stays on "d".
        let d = SaveTidy.tidy(text, selection: NSRange(location: 10, length: 1), trimTrailing: true, finalNewline: true)
        #expect((applied(text, d) as NSString).substring(with: d.edit!.selection) == "d")
    }

    @Test func crlfAndUnicode() {
        // Nib's buffer uses "\n", but a stray "\r\n" line keeps its "\r" (only spaces and tabs go).
        let text = "é😀  \nx\r\n"
        let r = SaveTidy.tidy(text, selection: NSRange(location: 0, length: 0), trimTrailing: true, finalNewline: true)
        #expect(applied(text, r) == "é😀\nx\r\n")
    }
}
