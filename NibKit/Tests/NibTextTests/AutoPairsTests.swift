// Matching brackets and closing pairs (PRD ED10), by Sublime's default rules.

import Foundation
import Testing

@testable import NibText

@Suite struct BracketsTests {
    func match(_ marked: String) -> String? {
        // "|" marks the caret.
        let caret = (marked as NSString).range(of: "|").location
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        guard let m = Brackets.match(in: text, caret: caret) else { return nil }
        return "\(m.open)-\(m.close)\(m.beside ? "" : " inside")"
    }

    @Test func besideTheCaret() {
        #expect(match("f(a, (b))|") == "1-8")        // a closer just typed: its opener
        #expect(match("f|(a, [b])") == "1-8")        // an opener after the caret
        #expect(match("f(a, [b]|)") == "5-7")        // brackets both sides: the one just typed, before it
        #expect(match("f(|a)") == "1-3")             // an opener before it
        #expect(match("f(a, [b|])") == "5-7")        // the nearest: ] after the caret
    }

    @Test func insideAPair() {
        #expect(match("{ a(b) | c[d] }") == "0-13 inside")
        #expect(match("x = [1, 2, (3 |+ 4)]") == "11-17 inside")
        #expect(match("no brackets |here") == nil)
        #expect(match("unmatched ( |") == nil)
    }

    @Test func eachTypeCountedOnItsOwn() {
        #expect(match("([)]|") == "1-3")   // ] goes back to [, the ) in between not its kind
    }

    @Test func aLimitKeepsItShort() {
        let far = "(" + String(repeating: "x", count: 1_000) + ")|"
        #expect(Brackets.match(in: far.replacingOccurrences(of: "|", with: "") as NSString, caret: 1_002, limit: 100) == nil)
        #expect(match(far) == "0-1001")
    }
}

@Suite struct AutoPairsTests {
    /// The text after typing `typed` at the "|" (or over the selection between two "|"s), with
    /// the caret (or selection) marked again.
    func typing(_ typed: String, _ marked: String) -> String {
        let ns = marked as NSString
        let first = ns.range(of: "|").location
        let second = ns.range(of: "|", options: .backwards).location
        let selection = NSRange(location: first, length: second == first ? 0 : second - first - 1)
        let text = marked.replacingOccurrences(of: "|", with: "") as NSString
        switch AutoPairs.typing(typed, in: text, selection: selection) {
        case .edit(let range, let made, let after):
            let out = NSMutableString(string: text)
            out.replaceCharacters(in: range, with: made)
            out.insert(after.length > 0 ? "|" : "", at: NSMaxRange(after))
            out.insert("|", at: after.location)
            return out as String
        case .skip(let to):
            let out = NSMutableString(string: text)
            out.insert("|", at: to)
            return out as String
        case nil:
            let out = NSMutableString(string: text)
            out.replaceCharacters(in: selection, with: typed)
            out.insert("|", at: selection.location + (typed as NSString).length)
            return out as String
        }
    }

    @Test func openersGetTheirClosers() {
        #expect(typing("(", "f|") == "f(|)")
        #expect(typing("[", "a = | ;") == "a = [|] ;")
        #expect(typing("{", "if x |\n") == "if x {|}\n")
        #expect(typing("(", "f|x") == "f(|x")   // before a word: no closer
    }

    @Test func quotesFollowSublimesRules() {
        #expect(typing("\"", "say |") == "say \"|\"")
        #expect(typing("'", "don|") == "don'|")          // an apostrophe, after a letter
        #expect(typing("'", "rock |n") == "rock '|n")    // before a word: none
        #expect(typing("`", "run |") == "run `|`")
    }

    @Test func aCloserAlreadyThereIsSteppedOver() {
        #expect(typing(")", "f(x|)") == "f(x)|")
        #expect(typing("\"", "\"hi|\"") == "\"hi\"|")
        #expect(typing("]", "a[|") == "a[]|")   // nothing to step over: typed
    }

    @Test func aSelectionIsWrapped() {
        #expect(typing("(", "a |b + c| d") == "a (|b + c|) d")
        #expect(typing("\"", "|word|") == "\"|word|\"")
        #expect(typing("x", "|word|") == "x|")   // not a pair: typed over it
    }

    @Test func backspaceTakesAnEmptyPair() {
        #expect(AutoPairs.deleting(in: "f()" as NSString, caret: 2) == NSRange(location: 1, length: 2))
        #expect(AutoPairs.deleting(in: "\"\"" as NSString, caret: 1) == NSRange(location: 0, length: 2))
        #expect(AutoPairs.deleting(in: "f(x)" as NSString, caret: 2) == nil)
    }

    @Test func returnBetweenBracketsOpensALine() {
        let made = AutoPairs.newline(in: "  if (x) {}" as NSString, caret: 10, indent: "  ", unit: "  ")
        #expect(made?.text == "\n    \n  " && made?.caret == 5)
        #expect(AutoPairs.newline(in: "a{b}" as NSString, caret: 2, indent: "", unit: "\t") == nil)
    }
}

@Suite struct CaretPairsTests {
    @Test func everyCaretClosesItsOwn() {
        // "f|" and "x = |;": both close; "g|h" doesn't (a word follows).
        let text = "f\nx = ;\ngh" as NSString
        let carets = Carets([Caret(1), Caret(6), Caret(9)])
        let (edits, after) = carets.typing("(", in: text, pairs: true)
        let out = NSMutableString(string: text)
        for edit in edits.reversed() { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        #expect(out as String == "f()\nx = ();\ng(h")
        #expect(after.all.map(\.head) == [2, 9, 14])
        // And stepping over the closers just made, at both, typing at the third.
        let (more, next) = after.typing(")", in: out, pairs: true)
        let out2 = NSMutableString(string: out)
        for edit in more.reversed() { out2.replaceCharacters(in: edit.range, with: edit.replacement) }
        #expect(out2 as String == "f()\nx = ();\ng()h" && next.all.map(\.head) == [3, 10, 15])
    }
}
