// Sublime's line commands (ED6, KB4): each edit, the selection after it, and the edges
// (the first and last line, a last line with no line break), and indentation found on open.

import Foundation
import Testing

@testable import NibText

@Suite struct LineEditsTests {
    /// The text after an edit, and the selection with a caret marked "|" (or "[…]").
    func apply(_ edit: LineEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        let after = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        let sel = edit.selection
        if sel.length == 0 { return after.replacingCharacters(in: sel, with: "|") }
        return after.replacingCharacters(in: sel, with: "[" + after.substring(with: sel) + "]")
    }

    /// Text with the caret marked "|": the text and the caret.
    func caret(_ marked: String) -> (String, NSRange) {
        let at = (marked as NSString).range(of: "|").location
        return (marked.replacingOccurrences(of: "|", with: ""), NSRange(location: at, length: 0))
    }

    @Test func duplicate() {
        var (text, sel) = caret("one\ntw|o\nthree\n")
        #expect(apply(LineEdits.duplicate(text, selection: sel), to: text) == "one\ntwo\ntw|o\nthree\n")
        (text, sel) = caret("one\ntw|o")   // the last line, no break
        #expect(apply(LineEdits.duplicate(text, selection: sel), to: text) == "one\ntwo\ntw|o")
        let words = "say hello there"
        #expect(apply(LineEdits.duplicate(words, selection: NSRange(location: 4, length: 5)), to: words) == "say hellohello there".replacingOccurrences(of: "hellohello", with: "hello[hello]"))
    }

    @Test func move() {
        var (text, sel) = caret("one\ntw|o\nthree\n")
        #expect(apply(LineEdits.move(text, selection: sel, up: true), to: text) == "tw|o\none\nthree\n")
        #expect(apply(LineEdits.move(text, selection: sel, up: false), to: text) == "one\nthree\ntw|o\n")
        (text, sel) = caret("one\ntwo\nthr|ee")   // up from a last line with no break
        #expect(apply(LineEdits.move(text, selection: sel, up: true), to: text) == "one\nthr|ee\ntwo")
        (text, sel) = caret("one\ntw|o\nthree")   // down onto a last line with no break
        #expect(apply(LineEdits.move(text, selection: sel, up: false), to: text) == "one\nthree\ntw|o")
        #expect(LineEdits.move("o|ne\ntwo", selection: NSRange(location: 1, length: 0), up: true) == nil)
    }

    @Test func selectLine() {
        let text = "one\ntwo\nthree\n"
        let first = LineEdits.selectLine(text, selection: NSRange(location: 5, length: 0))
        #expect(first == NSRange(location: 4, length: 4))                        // "two\n"
        #expect(LineEdits.selectLine(text, selection: first) == NSRange(location: 4, length: 10))   // and "three\n"
    }

    @Test func join() {
        var (text, sel) = caret("one| \n    two\nthree")
        #expect(apply(LineEdits.join(text, selection: sel), to: text) == "one| two\nthree")
        text = "a\n  b\n  c\nd"
        #expect(apply(LineEdits.join(text, selection: NSRange(location: 0, length: 8)), to: text) == "a| b c\nd")
        (text, sel) = caret("last|")
        #expect(LineEdits.join(text, selection: sel) == nil)
    }

    @Test func indentAndOutdent() {
        var (text, sel) = caret("if x {\nre|turn\n\n}\n")
        #expect(apply(LineEdits.indent(text, selection: sel, unit: "    "), to: text) == "if x {\n    re|turn\n\n}\n")
        let two = "a\n\nb\n"
        #expect(apply(LineEdits.indent(two, selection: NSRange(location: 0, length: 4), unit: "\t"), to: two)?.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") == "\ta\n\n\tb\n")   // blank lines stay blank
        (text, sel) = caret("      de|ep\n")
        #expect(apply(LineEdits.indent(text, selection: sel, unit: "    ", outdent: true, width: 4), to: text) == "  de|ep\n")
        (text, sel) = caret("\tta|b\n")
        #expect(apply(LineEdits.indent(text, selection: sel, unit: "\t", outdent: true), to: text) == "ta|b\n")
        (text, sel) = caret("fl|at\n")
        #expect(LineEdits.indent(text, selection: sel, unit: "  ", outdent: true) == nil)
    }

    @Test func lineComments() {
        var (text, sel) = caret("  let a = 1\n  let b| = 2\n")
        let js = CommentStyle.line("//")
        #expect(apply(LineEdits.toggleComment(text, selection: sel, style: js), to: text) == "  let a = 1\n  // let b| = 2\n")
        (text, sel) = caret("  // let b| = 2\n")
        #expect(apply(LineEdits.toggleComment(text, selection: sel, style: js), to: text) == "  let b| = 2\n")
        text = "if x\n  y\n\n  z\n"
        #expect(apply(LineEdits.toggleComment(text, selection: NSRange(location: 0, length: (text as NSString).length), style: .line("#")), to: text)
                == "[# if x\n#   y\n\n#   z]\n")
    }

    @Test func blockComments() {
        var (text, sel) = caret("  <p>he|llo</p>\n")
        let html = CommentStyle.block("<!--", "-->")
        #expect(apply(LineEdits.toggleComment(text, selection: sel, style: html), to: text) == "  <!-- <p>he|llo</p> -->\n")
        (text, sel) = caret("  <!-- <p>he|llo</p> -->\n")
        #expect(apply(LineEdits.toggleComment(text, selection: sel, style: html), to: text) == "  <p>he|llo</p>\n")
        text = "a {\n  color: red;\n}\n"
        #expect(apply(LineEdits.toggleComment(text, selection: NSRange(location: 0, length: (text as NSString).length), style: .block("/*", "*/")), to: text)
                == "[/* a {\n  color: red;\n} */]\n")
    }

    @Test func goToLine() {
        let text = "one\ntwo\nthree"
        #expect(LineEdits.start(ofLine: 1, in: text) == 0)
        #expect(LineEdits.start(ofLine: 3, in: text) == 8)
        #expect(LineEdits.start(ofLine: 99, in: text) == 8)   // past the end: the last line
    }

    @Test func indentationFound() {
        #expect(Indentation.detect(in: "a\n\tb\n\t\tc\n", fallback: .spaces(4)) == .tabs(width: 4))
        #expect(Indentation.detect(in: "a\n  b\n    c\n  d\n", fallback: .tabs(width: 4)) == .spaces(2))
        #expect(Indentation.detect(in: "a\n    b\n        c\n", fallback: .tabs(width: 4)) == .spaces(4))
        #expect(Indentation.detect(in: "plain\nlines\n", fallback: .tabs(width: 4)) == .tabs(width: 4))
    }

    /// Applies edits made in order, from the end.
    private func applied(_ edits: [Edit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.replacement) }
        return result as String
    }

    /// Convert Indentation (the QA review's F50): only each line's leading run, tabs to the next
    /// stop, what's left over in spaces.
    @Test func indentationConverted() {
        let spaced = "a\n  b\n    c\tafter\n   d\n\n"
        let tabbed = Indentation.tabs(width: 2).converting(spaced as NSString)
        #expect(applied(tabbed, to: spaced) == "a\n\tb\n\t\tc\tafter\n\t d\n\n")
        #expect(tabbed.count == 3)   // the lines that change, only
        let back = Indentation.spaces(2).converting(applied(tabbed, to: spaced) as NSString)
        #expect(applied(back, to: applied(tabbed, to: spaced)) == spaced)
        // A tab after spaces goes to the next stop: " \t" at width 4 is 4 columns.
        #expect(applied(Indentation.spaces(4).converting(" \tx\n\t  y" as NSString), to: " \tx\n\t  y") == "    x\n      y")
        // Nothing to do: no edits.
        #expect(Indentation.spaces(2).converting("a\n  b\n" as NSString).isEmpty)
        #expect(Indentation.tabs(width: 4).converting("" as NSString).isEmpty)
    }

    @Test func indentationKept() {
        for indentation in [Indentation.tabs(width: 4), .spaces(2), .tabs(width: 8), .spaces(3)] {
            #expect(Indentation(stored: indentation.stored) == indentation)
        }
        #expect(Indentation(stored: "spaces:0") == nil && Indentation(stored: "tabs") == nil && Indentation(stored: "dots:2") == nil)
    }

    /// Carets through edits made elsewhere: moved with the text before them.
    @Test func caretsMovedByEdits() {
        // "a\n    b\n": the leading run of line 2 (2..<6) made one tab.
        let edits = [Edit(range: NSRange(location: 2, length: 4), replacement: "\t")]
        // Before it; at its start; inside (as far as its text goes); at its end; after it. (One at a
        // time: carets that land on one place are merged.)
        let moved = [0, 2, 4, 6, 8].map { Carets([Caret($0)]).moved(by: edits).primaryCaret.head }
        #expect(moved == [0, 2, 3, 3, 5])
        let selection = Carets([Caret(anchor: 6, head: 8)]).moved(by: edits).primaryCaret
        #expect(selection.anchor == 3 && selection.head == 5)
    }
}
