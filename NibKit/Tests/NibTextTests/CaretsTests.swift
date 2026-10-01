// Several carets at once (PRD ED8): the arithmetic the text view's commands rest on.

import Foundation
import Testing

@testable import NibText

@Suite struct CaretsTests {
    /// The edits made to `text`, last first, as the text view makes them.
    func apply(_ edits: [Edit], to text: String) -> String {
        let out = NSMutableString(string: text)
        for edit in edits.reversed() { out.replaceCharacters(in: edit.range, with: edit.replacement) }
        return out as String
    }

    @Test func mergesAsSublimeDoes() {
        // Overlapping selections become one; a caret at a selection's edge goes into it; two
        // selections that only meet stay two; two carets at one place are one.
        let carets = Carets([Caret(anchor: 0, head: 4), Caret(anchor: 2, head: 6), Caret(6), Caret(anchor: 8, head: 10), Caret(anchor: 10, head: 12), Caret(14), Caret(14)])
        #expect(carets.ranges == [NSRange(location: 0, length: 6), NSRange(location: 8, length: 2), NSRange(location: 10, length: 2), NSRange(location: 14, length: 0)])
        #expect(carets.primary == 3, "the last one given, merged with its twin")
        // In any order given; the primary follows its caret.
        let shuffled = Carets([Caret(9), Caret(1), Caret(5)], primary: 0)
        #expect(shuffled.ranges.map(\.location) == [1, 5, 9] && shuffled.primary == 2)
        // A backward selection stays backward.
        #expect(Carets([Caret(anchor: 6, head: 2)]).all == [Caret(anchor: 6, head: 2)])
    }

    @Test func typingAtEveryCaret() {
        let text = "one\ntwo\nthree\n"
        let carets = Carets([Caret(0), Caret(4), Caret(8)])
        let (edits, after) = carets.replacing(with: ["- "])
        #expect(apply(edits, to: text) == "- one\n- two\n- three\n")
        #expect(after.all == [Caret(2), Caret(8), Caret(14)])
        // A selection is replaced, the caret after its text.
        let (more, then) = Carets([Caret(anchor: 0, head: 3), Caret(anchor: 4, head: 7)]).replacing(with: ["1"])
        #expect(apply(more, to: text) == "1\n1\nthree\n" && then.ranges.map(\.location) == [1, 3])
        // One line each (a paste of as many lines as carets).
        let (each, _) = carets.replacing(with: ["a", "bb", "ccc"])
        #expect(apply(each, to: text) == "aone\nbbtwo\ncccthree\n")
    }

    @Test func deletingBackward() {
        let text = "ab🙂cd" as NSString   // 🙂 is two UTF-16 units
        func before(_ location: Int) -> NSRange? { location == 0 ? nil : text.rangeOfComposedCharacterSequence(at: location - 1) }
        // After the emoji and at the end: the whole emoji goes, and one letter; the caret at 0, nothing.
        let (edits, after) = Carets([Caret(0), Caret(4), Caret(6)]).deleting(before)
        #expect(apply(edits, to: text as String) == "abc")
        #expect(after.ranges.map(\.location) == [0, 2, 3])
        // Two carets side by side, deleting back: what they take meets, and they become one.
        let (both, one) = Carets([Caret(1), Caret(2)]).deleting(before)
        #expect(apply(both, to: text as String) == "🙂cd" && one.count == 1 && one.primaryCaret.head == 0)
        // A selection deletes itself, whatever the span.
        let (selected, _) = Carets([Caret(anchor: 4, head: 6), Caret(1)]).deleting(before)
        #expect(apply(selected, to: text as String) == "b🙂")
    }

    @Test func accentsGoWithTheirLetters() {
        let text = "cafe\u{301}!" as NSString   // é as e and a combining accent
        let (edits, _) = Carets([Caret(5)]).deleting { text.rangeOfComposedCharacterSequence(at: $0 - 1) }
        #expect(apply(edits, to: text as String) == "caf!")
    }

    @Test func movingMergesWhatMeets() {
        let carets = Carets([Caret(2), Caret(3), Caret(9)], primary: 1)
        let left = carets.moving { Caret(max(0, $0.head - 3)) }
        #expect(left.ranges.map(\.location) == [0, 6] && left.primary == 0, "the two at the start are one, the primary with them")
        // Extending keeps each anchor.
        let extended = carets.moving { Caret(anchor: $0.anchor, head: $0.head + 1) }
        #expect(extended.all.map(\.anchor) == [2, 3, 9] && extended.all.map(\.head) == [3, 4, 10])
    }

    @Test func addingAndRemoving() {
        var carets = Carets([Caret(5)])
        carets = carets.adding(Caret(1))
        #expect(carets.ranges.map(\.location) == [1, 5] && carets.primary == 0, "the one added is the primary")
        carets = carets.adding(Caret(9))
        #expect(carets.removing(at: 5)?.ranges.map(\.location) == [1, 9])
        #expect(carets.removing(at: 7) == nil, "nothing there")
        #expect(Carets([Caret(3)]).removing(at: 3) == nil, "not the only one")
        // ⌘-click on a selection removes it.
        #expect(Carets([Caret(anchor: 2, head: 6), Caret(9)]).removing(at: 4)?.ranges == [NSRange(location: 9, length: 0)])
    }

    @Test func splittingIntoLines() {
        let text = "alpha\nbeta\n\ngamma\n" as NSString
        // A selection from the middle of alpha to the middle of gamma: one a line, empty lines too.
        let split = Carets([Caret(anchor: 2, head: 15)]).splitIntoLines(in: text)
        #expect(split.ranges == [NSRange(location: 2, length: 3), NSRange(location: 6, length: 4), NSRange(location: 11, length: 0), NSRange(location: 12, length: 3)])
        // Ending at a line's start leaves that line out; a caret stays.
        let lines = Carets([Caret(anchor: 0, head: 11), Caret(17)]).splitIntoLines(in: text)
        #expect(lines.ranges == [NSRange(location: 0, length: 5), NSRange(location: 6, length: 4), NSRange(location: 17, length: 0)])
    }

    @Test func occurrences() {
        let text = "let name = name + rename; Name name" as NSString
        #expect(Occurrences.word(at: 6, in: text) == NSRange(location: 4, length: 4), "inside a word")
        #expect(Occurrences.word(at: 8, in: text) == NSRange(location: 4, length: 4), "at its end")
        #expect(Occurrences.word(at: 9, in: text) == nil, "between")
        // ⌘D from a word: whole words only, case and all, going round to the start.
        let first = NSRange(location: 4, length: 4)
        let second = Occurrences.next("name", in: text, after: NSMaxRange(first), wholeWord: true, taken: [first])
        #expect(second == NSRange(location: 11, length: 4))
        let third = Occurrences.next("name", in: text, after: NSMaxRange(second!), wholeWord: true, taken: [first, second!])
        #expect(third == NSRange(location: 31, length: 4), "not re-name, not Name")
        #expect(Occurrences.next("name", in: text, after: 35, wholeWord: true, taken: [first, second!, third!]) == nil, "none left")
        // From a selection that isn't a word: any occurrence.
        #expect(Occurrences.next("name", in: text, after: 15, wholeWord: false, taken: []) == NSRange(location: 20, length: 4))
        #expect(Occurrences.all("name", in: text, wholeWord: true).map(\.location) == [4, 11, 31])
        #expect(Occurrences.all("na", in: "nana" as NSString, wholeWord: false).map(\.location) == [0, 2])
    }

    @Test func lineCommandsAtEveryCaret() {
        let text = "one\ntwo\nthree\nfour\n"
        func run(_ carets: Carets, _ groups: Carets.LineGroups = .sameLines, _ make: (NSRange) -> LineEdit?) -> (text: String, heads: [Int])? {
            carets.lineEdits(in: text, groups: groups, make).map { (apply($0.edits, to: text), $0.after.all.map(\.head)) }
        }
        // Indent at carets on lines 1 and 3, and two on line 4: each line once, every caret kept in its place.
        let indented = run(Carets([Caret(1), Caret(9), Caret(15), Caret(17)])) { LineEdits.indent(text, selection: $0, unit: "\t") }
        #expect(indented?.text == "\tone\ntwo\n\tthree\n\tfour\n" && indented?.heads == [2, 11, 18, 20], "\(String(describing: indented))")
        // Outdent takes it back, the carets with it.
        let tabbed = "\tone\ntwo\n"
        let outdented = Carets([Caret(0), Caret(2), Caret(6)]).lineEdits(in: tabbed) { LineEdits.indent(tabbed, selection: $0, unit: "\t", outdent: true) }
        #expect(outdented.map { apply($0.edits, to: tabbed) } == "one\ntwo\n" && outdented?.after.all.map(\.head) == [0, 1, 5])
        // Toggle Comment, each caret's lines on their own: commented, and a commented one not.
        let mixed = "// one\ntwo\n"
        let toggled = Carets([Caret(4), Caret(8)]).lineEdits(in: mixed) { LineEdits.toggleComment(mixed, selection: $0, style: .line("//")) }
        #expect(toggled.map { apply($0.edits, to: mixed) } == "one\n// two\n" && toggled?.after.all.map(\.head) == [1, 8])
        // Two carets on one line commented: both after the mark, each by its own text.
        let both = run(Carets([Caret(4), Caret(6)])) { LineEdits.toggleComment(text, selection: $0, style: .line("//")) }
        #expect(both?.text == "one\n// two\nthree\nfour\n" && both?.heads == [7, 9])
        // A block comment's close stays after a caret at the line's end.
        let block = run(Carets([Caret(4), Caret(7)])) { LineEdits.toggleComment(text, selection: $0, style: .block("/*", "*/")) }
        #expect(block?.text == "one\n/* two */\nthree\nfour\n" && block?.heads == [7, 10])
        // Duplicate Line: each line doubled, the carets on the copies.
        let doubled = run(Carets([Caret(1), Caret(9), Caret(10)])) { LineEdits.duplicate(text, selection: $0) }
        #expect(doubled?.text == "one\none\ntwo\nthree\nthree\nfour\n" && doubled?.heads == [5, 19, 20], "\(String(describing: doubled))")
        // Join Lines from a column of three: all four lines one.
        let joined = run(Carets([Caret(0), Caret(4), Caret(8)]), .joins) { LineEdits.join(text, selection: $0) }
        #expect(joined?.text == "one two three four\n" && joined?.heads.count == 1)
        // Two apart: each its line and the next.
        let pairs = run(Carets([Caret(0), Caret(8)]), .joins) { LineEdits.join(text, selection: $0) }
        #expect(pairs?.text == "one two\nthree four\n" && pairs?.heads == [3, 13])
        // Move Line Down from carets on lines 1 and 2: the block moves, the carets with it.
        let moved = run(Carets([Caret(1), Caret(5)]), .block) { LineEdits.move(text, selection: $0, up: false) }
        #expect(moved?.text == "three\none\ntwo\nfour\n" && moved?.heads == [7, 11])
        // Lines apart move each on their own; at the top, a line can't move up, the others do.
        let up = run(Carets([Caret(0), Caret(9)]), .block) { LineEdits.move(text, selection: $0, up: true) }
        #expect(up?.text == "one\nthree\ntwo\nfour\n" && up?.heads == [0, 5])
        // Nothing to do at any caret: nil.
        #expect(Carets([Caret(0), Caret(1)]).lineEdits(in: "\n\n") { LineEdits.indent("\n\n", selection: $0, unit: "\t") } == nil)
    }

    @Test func shiftsMapCarets() {
        let edit = LineEdit(range: NSRange(location: 0, length: 10), replacement: "", selection: NSRange(location: 0, length: 0),
                            shifts: [.init(at: 2, delta: 3), .init(at: 6, delta: -2), .init(at: 9, delta: 1, stays: true)])
        // Before the insertion, at it (after it), inside the removal, after it, at the stay.
        #expect([0, 2, 3, 6, 7, 8, 9, 10].map(edit.map) == [0, 5, 6, 9, 9, 9, 10, 12])
    }

    /// Random carets and texts, against making each edit alone from the last to the first.
    @Test func randomEditsMatchOneAtATime() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % max(1, n)
        }
        for _ in 0..<500 {
            let text = String((0..<(5 + next(40))).map { _ in "ab \n🙂"[String.Index(utf16Offset: [0, 1, 2, 3, 4][next(5)], in: "ab \n🙂")] })
            let ns = text as NSString
            func point() -> Int {   // not inside the emoji's pair
                var p = next(ns.length + 1)
                if p > 0, p < ns.length, UTF16.isTrailSurrogate(ns.character(at: p)) { p -= 1 }
                return p
            }
            let carets = Carets((0..<(1 + next(5))).map { _ in Caret(anchor: point(), head: point()) })
            let choices = ["x", "", "yy", "\n", "🙂"]
            let texts = next(2) == 0 ? [choices[next(choices.count)]] : (0..<carets.count).map { _ in choices[next(choices.count)] }
            let (edits, after) = carets.replacing(with: texts)
            // One at a time, from the last caret to the first: the same text.
            var expected = text
            for edit in edits.reversed() { expected = (expected as NSString).replacingCharacters(in: edit.range, with: edit.replacement) }
            #expect(apply(edits, to: text) == expected)
            // Each caret after is just after its own text.
            var shift = 0
            for (edit, caret) in zip(edits, after.all) {
                shift += (edit.replacement as NSString).length - edit.range.length
                #expect(caret.head == NSMaxRange(edit.range) + shift)
            }
        }
    }
}
