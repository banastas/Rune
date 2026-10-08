// Conflict blocks found in the text and resolved (PRD §4.7, §5.4): what Keep Both and the
// merge write, what git writes, and what isn't a block.

import Foundation
import Testing

@testable import NibText

@Suite struct ConflictBlockTests {
    let text = "intro\n<<<<<<< Air · 10:42\nFriday.\n=======\nThursday.\n>>>>>>> Mini · 10:41\noutro\n"

    func sub(_ s: String, _ r: NSRange) -> String { (s as NSString).substring(with: r) }

    @Test func findsABlockAndItsSides() {
        let blocks = ConflictText.blocks(in: text)
        #expect(blocks.count == 1)
        let b = blocks[0]
        #expect(sub(text, b.range) == "<<<<<<< Air · 10:42\nFriday.\n=======\nThursday.\n>>>>>>> Mini · 10:41\n")
        #expect(sub(text, b.first) == "Friday.\n")
        #expect(sub(text, b.second) == "Thursday.\n")
        #expect(b.firstLabel == "Air · 10:42" && b.secondLabel == "Mini · 10:41")
        #expect(b.markers.map { sub(text, $0) } == ["<<<<<<< Air · 10:42\n", "=======\n", ">>>>>>> Mini · 10:41\n"])
    }

    @Test func resolvesEachWay() {
        let b = ConflictText.blocks(in: text)[0]
        func apply(_ choice: ConflictBlock.Choice) -> String {
            (text as NSString).replacingCharacters(in: b.range, with: ConflictText.resolution(of: b, choice, in: text))
        }
        #expect(apply(.first) == "intro\nFriday.\noutro\n")
        #expect(apply(.second) == "intro\nThursday.\noutro\n")
        #expect(apply(.both) == "intro\nFriday.\nThursday.\noutro\n")
    }

    @Test func whatMergeWritesIsFoundAgain() {
        let base = "notes\n- lead\n"
        let merged = Merge.threeWay(base: base, .init(text: base + "\n- b\n", label: "Mini · 1"), .init(text: base + "\n- a\n", label: "Air · 1"))
        let blocks = ConflictText.blocks(in: merged.text)
        #expect(blocks.count == merged.conflicts && blocks.count == 1)
        let both = (merged.text as NSString).replacingCharacters(in: blocks[0].range, with: ConflictText.resolution(of: blocks[0], .both, in: merged.text))
        #expect(both == "notes\n- lead\n\n- a\n- b\n")
    }

    @Test func twoBlocks() {
        let two = "a\n<<<<<<< X\n1\n=======\n2\n>>>>>>> Y\nb\n<<<<<<< X\n3\n=======\n>>>>>>> Y\n"
        let blocks = ConflictText.blocks(in: two)
        #expect(blocks.count == 2)
        #expect(sub(two, blocks[1].second) == "")
        #expect((two as NSString).replacingCharacters(in: blocks[1].range, with: ConflictText.resolution(of: blocks[1], .second, in: two)) == "a\n<<<<<<< X\n1\n=======\n2\n>>>>>>> Y\nb\n")
    }

    @Test func aBlockOnTheLastLineKeepsNoBreak() {
        let t = "a\n<<<<<<< X\n1\n=======\n2\n>>>>>>> Y"
        let b = ConflictText.blocks(in: t)[0]
        #expect((t as NSString).replacingCharacters(in: b.range, with: ConflictText.resolution(of: b, .both, in: t)) == "a\n1\n2")
    }

    @Test func gitsBaseSectionIsAMarker() {
        let t = "<<<<<<< HEAD\nmine\n||||||| base\nold\n=======\ntheirs\n>>>>>>> branch\n"
        let b = ConflictText.blocks(in: t)[0]
        #expect(sub(t, b.first) == "mine\n" && sub(t, b.second) == "theirs\n")
        #expect(b.markers.map { sub(t, $0) } == ["<<<<<<< HEAD\n", "||||||| base\nold\n=======\n", ">>>>>>> branch\n"])
    }

    @Test func eachSidesWholeText() {
        let two = "a\n<<<<<<< X\n1\n=======\n2\n>>>>>>> Y\nb\n<<<<<<< X\n3\n=======\n>>>>>>> Y\nc\n"
        let sides = ConflictText.sides(of: two)
        #expect(sides.first == "a\n1\nb\n3\nc\n")
        #expect(sides.second == "a\n2\nb\nc\n")
    }

    @Test func lineMarksAgainstTheOtherSide() {
        let (a, b) = ConflictText.lineMarks("hi\nFriday\ninvoice\n", "hi\nThursday\n")
        #expect(a == [.same, .changed, .changed, .same])   // "Friday", "invoice" against "Thursday"
        #expect(b == [.same, .changed, .same])
        let (c, d) = ConflictText.lineMarks("hi\nextra\nbye\n", "hi\nbye\n")
        #expect(c == [.same, .only, .same, .same])
        #expect(d == [.same, .same, .same])
    }

    @Test func maskingBlanksTheMarkersOnly() {
        let masked = ConflictText.masked(text)
        #expect((masked as NSString).length == (text as NSString).length)
        #expect(masked == "intro\n                   \nFriday.\n       \nThursday.\n                    \noutro\n")
        #expect(ConflictText.masked("plain\n") == "plain\n")
    }

    @Test func notBlocks() {
        #expect(ConflictText.blocks(in: "plain\ntext\n").isEmpty)
        #expect(ConflictText.blocks(in: "<<<<<<< X\nno end\n=======\nstill none\n").isEmpty)
        #expect(ConflictText.blocks(in: "<<<<<<<< eight\n=======\n>>>>>>> Y\n").isEmpty)   // eight, not seven
        #expect(ConflictText.blocks(in: "=======\n>>>>>>> Y\n").isEmpty)
        // A start that never ends, then a whole block: only the whole one.
        let t = "<<<<<<< lost\nx\n<<<<<<< X\n1\n=======\n2\n>>>>>>> Y\n"
        #expect(ConflictText.blocks(in: t).count == 1)
        #expect(ConflictText.blocks(in: t)[0].firstLabel == "X")
    }
}
