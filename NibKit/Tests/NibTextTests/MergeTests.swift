// The three-way merge (PRD §4.7): clean merges, merges within a line, conflict blocks,
// deterministic output (SY10), and a seeded fuzz for the one promise that matters most:
// a line either side added is never lost.

import Testing

@testable import NibText

@Suite struct MergeTests {
    let air = { (text: String) in ConflictText.Side(text: text, label: "Air · 10:42") }
    let mini = { (text: String) in ConflictText.Side(text: text, label: "Mini · 10:41") }

    @Test func identicalSidesAreThemselves() {
        let r = Merge.threeWay(base: "a\n", air("a\nb\n"), mini("a\nb\n"))
        #expect(r == Merge.Result(text: "a\nb\n", conflicts: 0, changesFromFirst: 0, changesFromSecond: 0, withinLine: false))
    }

    @Test func oneSideUnchangedTakesTheOther() {
        let r = Merge.threeWay(base: "a\nb\n", air("a\nb\n"), mini("a\nB\nc\n"))
        #expect(r.text == "a\nB\nc\n")
        #expect(r.isClean && r.changesFromFirst == 0 && r.changesFromSecond == 1)
    }

    @Test func separateEditsMergeCleanly() {
        let base = "one\ntwo\nthree\nfour\n"
        let r = Merge.threeWay(base: base, air("ONE\ntwo\nthree\nfour\n"), mini("one\ntwo\nthree\nfour\nfive\n"))
        #expect(r.text == "ONE\ntwo\nthree\nfour\nfive\n")
        #expect(r.isClean && r.changesFromFirst == 1 && r.changesFromSecond == 1 && !r.withinLine)
    }

    @Test func theSameChangeOnBothIsTakenOnce() {
        let r = Merge.threeWay(base: "a\nb\nc\n", air("a\nB\nc\nx\n"), mini("a\nB\nc\n"))
        #expect(r.text == "a\nB\nc\nx\n")
        #expect(r.isClean)
    }

    @Test func adjacentLinesMergeWordByWord() {
        let r = Merge.threeWay(base: "a\nb\nc\nd\n", air("a\nB\nc\nd\n"), mini("a\nb\nC\nd\n"))
        #expect(r.text == "a\nB\nC\nd\n")
        #expect(r.isClean && r.withinLine)
    }

    @Test func differentWordsInOneLineMerge() {
        let base = "We can ship on Friday if QA signs off.\n"
        let r = Merge.threeWay(base: base, air("We can ship on Thursday if QA signs off.\n"), mini("We can ship on Friday if QA approves.\n"))
        #expect(r.text == "We can ship on Thursday if QA approves.\n")
        #expect(r.isClean && r.withinLine && r.changesFromFirst == 1 && r.changesFromSecond == 1)
    }

    @Test func theSameWordsChangedDifferentlyAreAConflict() {
        let base = "intro\nWe can ship on Friday.\noutro\n"
        let r = Merge.threeWay(base: base, air("Intro\nWe can ship on Thursday.\noutro\n"), mini("intro\nWe can ship on Monday.\noutro!\n"))
        // Air's label sorts first; the clean edits outside the block are merged.
        #expect(r.text == "Intro\n<<<<<<< Air · 10:42\nWe can ship on Thursday.\n=======\nWe can ship on Monday.\n>>>>>>> Mini · 10:41\noutro!\n")
        #expect(r.conflicts == 1)
    }

    @Test func bothAddingAtTheEndIsOneBlockWithEachLineOnce() {
        // The two-Mac test's clash.
        let base = "notes\n- lead\n"
        let r = Merge.threeWay(base: base, mini(base + "- clash from b\n"), air(base + "- clash from a\n"))
        #expect(r.text == "notes\n- lead\n<<<<<<< Air · 10:42\n- clash from a\n=======\n- clash from b\n>>>>>>> Mini · 10:41\n")
        #expect(r.conflicts == 1)
    }

    @Test func sidesInEitherOrderGiveTheSameBytes() {
        let base = "a\nb\nc\nd\ne\n"
        let x = air("A\nb\nc\nd\ne\nair\n"), y = mini("a\nb\nC\nd\ne\nmini\n")
        let one = Merge.threeWay(base: base, x, y), two = Merge.threeWay(base: base, y, x)
        #expect(one.text == two.text)
        #expect(one.changesFromFirst == two.changesFromSecond && one.changesFromSecond == two.changesFromFirst)
    }

    @Test func anAdditionThatCarriesTheOtherIsTaken() {
        let r = Merge.threeWay(base: "a\n", air("a\nx\n"), mini("a\nx\ny\n"))
        #expect(r.text == "a\nx\ny\n")
        #expect(r.isClean)
    }

    @Test func deletingALineTheOtherSideEditedIsAConflict() {
        let r = Merge.threeWay(base: "a\nb\nc\n", air("a\nc\n"), mini("a\nB!\nc\n"))
        #expect(r.conflicts == 1)
        #expect(r.text.contains("B!"))
    }

    @Test func aDeletionElsewhereIsApplied() {
        let r = Merge.threeWay(base: "a\nb\nc\nd\n", air("a\nc\nd\n"), mini("a\nb\nc\nD\n"))
        #expect(r.text == "a\nc\nD\n")
        #expect(r.isClean)
    }

    @Test func noFinalNewlineIsKept() {
        let r = Merge.threeWay(base: "a\nb", air("A\nb"), mini("a\nb\nc"))
        #expect(r.text == "A\nb\nc")
    }

    @Test func wordsJoinBackToTheText() {
        for text in ["", "a", "  two  spaces\tand tab\n\nblank line ", "é ü\n"] {
            #expect(Merge.words(text).joined() == text)
        }
    }

    /// Random edits on both sides of a 12-line base: every line either side added is in
    /// the merge (merged, or inside a conflict block), and the order of the sides doesn't
    /// change the bytes.
    @Test func fuzzNothingAddedIsLost() {
        var rng = SeededRandom(seed: 0x6E6962)
        for round in 0..<2000 {
            let base = (0..<12).map { "l\($0)" }
            func edit(_ side: String) -> (lines: [String], added: [String]) {
                var lines = base, added: [String] = []
                for n in 0..<Int.random(in: 1...4, using: &rng) {
                    let line = "\(side)-\(round)-\(n)"
                    switch Int.random(in: 0..<3, using: &rng) {
                    case 0 where !lines.isEmpty:
                        lines[Int.random(in: 0..<lines.count, using: &rng)] = line; added.append(line)
                    case 1 where !lines.isEmpty:
                        lines.remove(at: Int.random(in: 0..<lines.count, using: &rng))
                    default:
                        lines.insert(line, at: Int.random(in: 0...lines.count, using: &rng)); added.append(line)
                    }
                }
                return (lines, added.filter { lines.contains($0) })
            }
            let x = edit("air"), y = edit("mini")
            let join = { (lines: [String]) in lines.joined(separator: "\n") + "\n" }
            let one = Merge.threeWay(base: join(base), air(join(x.lines)), mini(join(y.lines)))
            let two = Merge.threeWay(base: join(base), mini(join(y.lines)), air(join(x.lines)))
            let merged = Set(one.text.split(separator: "\n").map(String.init))
            for line in x.added + y.added { #expect(merged.contains(line), "round \(round): lost \(line)") }
            #expect(one.text == two.text, "round \(round): order changed the bytes")
        }
    }
}

/// SplitMix64, so the fuzz is the same on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
