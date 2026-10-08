// The line index (ED6): lines found, looked up by offset, and kept right through edits
// anywhere, checked against an index made afresh.

import Foundation
import Testing

@testable import NibText

@Suite struct LineIndexTests {
    @Test func linesAndLookups() {
        let index = LineIndex("one\ntwo\n\nfour" as NSString)
        #expect(index.starts == [0, 4, 8, 9] && index.lineCount == 4)
        #expect(index.line(at: 0) == 1 && index.line(at: 3) == 1 && index.line(at: 4) == 2 && index.line(at: 8) == 3 && index.line(at: 13) == 4)
        #expect(index.line(at: 100) == 4 && index.start(ofLine: 2) == 4 && index.start(ofLine: 5) == nil)
        #expect(LineIndex("" as NSString).lineCount == 1 && LineIndex("a\n" as NSString).lineCount == 2)   // the empty line after a final newline counts
    }

    @Test func editsKeepItRight() {
        var text = NSMutableString(string: "alpha\nbeta\ngamma\n")
        var index = LineIndex(text)
        var generator = SystemRandomNumberGenerator()
        let pieces = ["", "x", "\n", "\n\n", "ab\ncd", "\nq", "zz", "é\n😀\n"]
        for _ in 0..<2_000 {
            let location = Int.random(in: 0...text.length, using: &generator)
            let length = Int.random(in: 0...min(6, text.length - location), using: &generator)
            let piece = pieces.randomElement(using: &generator)! as NSString
            text.replaceCharacters(in: NSRange(location: location, length: length), with: piece as String)
            index.update(text, edited: NSRange(location: location, length: piece.length), delta: piece.length - length)
            #expect(index == LineIndex(text), "after replacing \(length) at \(location) with \(piece)")
            if index != LineIndex(text) { return }
            if text.length > 400 { text = NSMutableString(string: text.substring(to: 100)); index = LineIndex(text) }
        }
    }
}
