// CSV and logs (PRD HL8), Nib's own colors with no tree (LineSyntax): CSV's columns in turn,
// its quotes over line breaks, its separators; a log's timestamps, levels, strings, URLs and
// numbers; and a document's stretches, read on from the records' starts it keeps, the same as
// the whole text's.

import Foundation
import Testing

@testable import NibSyntax
@testable import NibText

@Suite struct LineSyntaxTests {
    let theme = Theme.anOldHopeNib

    /// The color drawn at `word`'s first character (or `shift` characters on), at its `nth` place in the text.
    func color(of word: String, _ nth: Int = 0, shift: Int = 0, in text: String, _ language: SyntaxLanguage, root: String? = nil) -> String {
        let ns = text as NSString
        var at = ns.range(of: word).location
        for _ in 0..<nth where at != NSNotFound { at = ns.range(of: word, range: NSRange(location: at + 1, length: ns.length - at - 1)).location }
        guard at != NSNotFound, let run = Highlighter.runs(text, language: language, root: root).first(where: { NSLocationInRange(at + shift, $0.range) })
        else { return "not found" }
        return theme.style(for: run.scopes).foreground.hex
    }

    @Test func csvColumnsTakeTheColorsInTurn() {
        let csv = "a1,b1,c1,d1,e1,f1,g1,h1\n"
        let colors = ["a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1"].map { color(of: $0, in: csv, .csv) }
        #expect(colors == ["#F8F8F2", "#EC475D", "#E7CE57", "#78BC65", "#50B4D8", "#EF7C2B", "#F8F8F2", "#EC475D"])
        // The separators plain; a quoted field one color, its commas, "" and line breaks too.
        let quoted = "id,notes,n\n1,\"one, \"\"two\"\"\nthree\",4\n5,six,7\n"
        #expect(color(of: ",notes", in: quoted, .csv) == "#F8F8F2")
        for part in ["\"one", "two", "three", "\","] { #expect(color(of: part, in: quoted, .csv) == "#EC475D", "\(part)") }
        #expect(color(of: "4", in: quoted, .csv) == "#E7CE57")    // the record goes on after the line break
        #expect(color(of: "six", in: quoted, .csv) == "#EC475D")  // and the next starts at the first column
        // A quote inside a field is text; only one at a field's start opens it.
        let inner = "size,note\n5'4\" tall,x\n"
        #expect(color(of: "x", in: inner, .csv) == "#EC475D")
    }

    @Test func csvSeparators() {
        // A .csv file's separator: what its first line has most of, outside quotes.
        let semicolons = "name;\"amount, net\";date\nTea;3,50;2026-10-02\n"
        #expect(color(of: "3,50", in: semicolons, .csv) == "#EC475D")
        #expect(color(of: "2026", in: semicolons, .csv) == "#E7CE57")
        let tabs = "name\tamount\nTea\t3\n"
        #expect(color(of: "3", in: tabs, .csv) == "#EC475D")
        let bars = "a|b|c\n1|2|3\n"
        #expect(color(of: "3", in: bars, .csv) == "#E7CE57")
        // Excel's sep= line.
        let excel = "sep=;\nname;amount\nTea;3,5\n"
        #expect(color(of: "3,5", in: excel, .csv) == "#EC475D")
        // A .tsv file's: tabs, and its quotes are text.
        let tsv = "a\t\"b\tc\"\td\n"
        let (language, root) = SyntaxLanguage.detect(fileName: "table.tsv")!
        #expect(color(of: "c\"", in: tsv, language, root: root) == "#E7CE57")
        #expect(color(of: "d", in: tsv, language, root: root) == "#78BC65")
    }

    @Test func logColors() {
        let log = """
        2026-10-02 17:24:01.123 INFO  [sync] opened "scratch.md" in 112ms
        2026-10-02T17:24:09Z WARN retrying in 15s (attempt 2 of 5)
        Oct  2 17:24:24 studio Nib[4211]: ERROR upload failed: storage full
        [02/Oct/2026:17:25:30 +0000] level=debug id=550e8400-e29b-41d4-a716-446655440000 ok=true see https://example.com/s?id=42.
        17:25:41.500 [error] 0x1f3a errors in 20.0s; Information follows
        """
        #expect(color(of: "2026-10-02 17", in: log, .log) == "#848484")
        #expect(color(of: "INFO", in: log, .log) == "#78BC65")
        #expect(color(of: "sync", in: log, .log) == "#F8F8F2")
        #expect(color(of: "scratch", in: log, .log) == "#50B4D8")
        #expect(color(of: "112ms", in: log, .log) == "#EF7C2B")
        #expect(color(of: "2026-10-02T", in: log, .log) == "#848484")
        #expect(color(of: "WARN", in: log, .log) == "#E7CE57")
        #expect(color(of: "15s", in: log, .log) == "#EF7C2B")
        #expect(color(of: "Oct  2", in: log, .log) == "#848484")
        #expect(color(of: "4211", in: log, .log) == "#EF7C2B")
        #expect(color(of: "ERROR", in: log, .log) == "#EC475D")
        #expect(color(of: "failed:", in: log, .log) == "#EC475D")
        #expect(color(of: "storage", in: log, .log) == "#F8F8F2")
        #expect(color(of: "02/Oct", in: log, .log) == "#848484")
        #expect(color(of: "debug", in: log, .log) == "#848484")
        #expect(color(of: "550e8400", in: log, .log) == "#EF7C2B")
        #expect(color(of: "true", in: log, .log) == "#EF7C2B")
        #expect(color(of: "https", in: log, .log) == "#50B4D8")
        #expect(color(of: "42.", in: log, .log) == "#50B4D8")
        #expect(color(of: "42.", shift: 2, in: log, .log) == "#F8F8F2")   // a URL's end isn't its sentence's
        #expect(color(of: "17:25:41", in: log, .log) == "#848484")
        #expect(color(of: "error]", in: log, .log) == "#EC475D")
        #expect(color(of: "0x1f3a", in: log, .log) == "#EF7C2B")
        #expect(color(of: "errors", in: log, .log) == "#F8F8F2")   // a word, not a level
        #expect(color(of: "Information", in: log, .log) == "#78BC65")
    }

    /// A line over 64K is left plain (a whole minified log on one line), and the next isn't.
    @Test func aVeryLongLogLineIsPlain() {
        let log = "ERROR " + String(repeating: "x ", count: 40_000) + "\nERROR next\n"
        #expect(color(of: "ERROR", in: log, .log) == "#F8F8F2")
        #expect(color(of: "ERROR", 1, in: log, .log) == "#EC475D")
    }

    /// A document's stretches of a big CSV, through edits that move quotes, separators and line
    /// breaks: read on from the records' starts it keeps, they're the whole text's, cut.
    @Test func csvStretchesAfterEdits() async {
        var generator = SplitMix(seed: 20261002)
        var text = "id,title,notes,n\n"
        var row = 0
        while (text as NSString).length < 120_000 {
            row += 1
            switch row % 7 {
            case 0: text += "\(row),\"Quoted, with \"\"marks\"\"\",\"over\ntwo lines\",\(row * 3)\n"
            case 3: text += "\(row),plain,,\(row)\n"
            default: text += "\(row),Episode \(row),Notes for \(row),\(row % 60)\n"
            }
        }
        let document = SyntaxDocument(language: .csv, root: "text.csv")
        await document.update(text)
        for step in 0..<60 {
            let ns = text as NSString
            if step > 0 {
                let at = Int(generator.next() % UInt64(ns.length + 1))
                let cut = min(ns.length - at, Int(generator.next() % 6))
                let insert = ["", "\"", ",", "\n", "x", "\"\"", "\",\""][Int(generator.next() % 7)]
                text = ns.replacingCharacters(in: NSRange(location: at, length: cut), with: insert)
                await document.update(text)
            }
            let length = (text as NSString).length
            for _ in 0..<3 {
                let start = Int(generator.next() % UInt64(length))
                let window = NSRange(location: start, length: min(length - start, 1 + Int(generator.next() % 20_000)))
                let expected = Highlighter.runs(text, language: .csv, root: "text.csv", in: window)
                #expect(await document.runs(in: window) == expected, "step \(step) \(window)")
            }
        }
        #expect(await document.recordMarks.count > 2)   // it kept records' starts along the way
    }
}
