// The smallest change between two texts (PRD §6.5's reload): applied, it always gives the new
// text; nothing for the same text; whole characters only (emoji are two UTF-16 units); and
// quick at the scratch file's size.

import Foundation
import Testing

@testable import NibText

@Suite struct TextDeltaTests {
    func apply(_ change: TextDelta.Change?, to old: String) -> String {
        guard let change else { return old }
        return (old as NSString).replacingCharacters(in: change.range, with: change.replacement)
    }

    @Test func small() {
        #expect(TextDelta.change(from: "same" as NSString, to: "same" as NSString) == nil)
        #expect(TextDelta.change(from: "abc" as NSString, to: "abXc" as NSString) == .init(range: NSRange(location: 2, length: 0), replacement: "X"))
        #expect(TextDelta.change(from: "line one\nline two\n" as NSString, to: "line one\nline two\nthree\n" as NSString)
                == .init(range: NSRange(location: 18, length: 0), replacement: "three\n"))
        #expect(apply(TextDelta.change(from: "aaa" as NSString, to: "aa" as NSString), to: "aaa") == "aa")
        #expect(apply(TextDelta.change(from: "" as NSString, to: "new" as NSString), to: "") == "new")
        #expect(apply(TextDelta.change(from: "old" as NSString, to: "" as NSString), to: "old") == "")
    }

    @Test func surrogatesStayWhole() {
        // 😀 and 😃 share their lead surrogate: the change must take the whole character.
        let old = "a😀b", new = "a😃b"
        let change = TextDelta.change(from: old as NSString, to: new as NSString)
        #expect(change?.replacement == "😃" && change?.range == NSRange(location: 1, length: 2))
        #expect(apply(change, to: old) == new)
    }

    @Test func randomEdits() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\n é😀")
        for _ in 0..<2_000 {
            let old = String((0..<Int.random(in: 0..<40, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            var new = old
            for _ in 0..<Int.random(in: 0...3, using: &generator) {
                let at = new.index(new.startIndex, offsetBy: Int.random(in: 0...new.count, using: &generator))
                if Bool.random(using: &generator), at < new.endIndex { new.remove(at: at) }
                else { new.insert(alphabet.randomElement(using: &generator)!, at: at) }
            }
            let change = TextDelta.change(from: old as NSString, to: new as NSString)
            #expect(apply(change, to: old) == new, "\(old.debugDescription) → \(new.debugDescription): \(String(describing: change))")
            if old == new { #expect(change == nil) }
        }
    }

    @Test func scratchSized() {
        var text = "# Scratch\n", n = 0
        while text.utf8.count < 2_400_000 { n += 1; text += "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
        let changed = text + "## Another app's line\n"
        let start = Date()
        let change = TextDelta.change(from: text as NSString, to: changed as NSString)
        let seconds = Date().timeIntervalSince(start)
        print("compared 2.4 MB in \(Int(seconds * 1000)) ms")
        #expect(change == .init(range: NSRange(location: (text as NSString).length, length: 0), replacement: "## Another app's line\n"))
    }

    @Test func sameIsUnitForUnit() {
        let big = String(repeating: "Line of text for the scratch file.\n", count: 70_000) as NSString
        #expect(TextDelta.same(big, NSString(string: big as String)))
        #expect(!TextDelta.same(big, big.replacingCharacters(in: NSRange(location: 1_000_000, length: 1), with: "X") as NSString))
        #expect(!TextDelta.same(big, (big as String) + "\n" as NSString))
        // Swift's == takes these as the same text; a file holds different bytes.
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        #expect(composed == decomposed)
        #expect(!TextDelta.same(composed as NSString, decomposed as NSString))
    }
}
