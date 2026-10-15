// Changes since the last commit (PRD ED12): lines added, changed and deleted, as the gutter marks them.

import Foundation
import Testing

@testable import NibText

@Suite struct LineChangesTests {
    let committed = "one\ntwo\nthree\nfour\nfive\n"

    @Test func noChanges() {
        let changes = LineChanges.between(committed: committed, text: committed)
        #expect(changes.isEmpty)
        #expect(changes.summary == "NO CHANGES SINCE THE LAST COMMIT")
        #expect(LineChanges.between(committed: "a\r\nb\r\n", text: "a\nb\n").isEmpty, "line endings set aside")
    }

    @Test func changedLine() {
        let changes = LineChanges.between(committed: committed, text: "one\nTWO\nthree\nfour\nfive\n")
        #expect(changes.lines == [1: .modified])
        #expect(changes.modified == 1 && changes.added == 0 && changes.deleted == 0)
    }

    @Test func addedLines() {
        let changes = LineChanges.between(committed: committed, text: "one\ntwo\nnew a\nnew b\nthree\nfour\nfive\nlast\n")
        #expect(changes.lines == [2: .added, 3: .added, 7: .added])
        #expect(changes.summary == "3 ADDED")
    }

    @Test func deletedLines() {
        let middle = LineChanges.between(committed: committed, text: "one\nfour\nfive\n")
        #expect(middle.lines.isEmpty && middle.deletedBefore == [1] && middle.deleted == 2, "marked before the line after them")
        let end = LineChanges.between(committed: committed, text: "one\ntwo\nthree\n")
        #expect(end.deletedBefore == [3] && end.deleted == 2, "at the end: before the line count")
        let start = LineChanges.between(committed: committed, text: "three\nfour\nfive\n")
        #expect(start.deletedBefore == [0])
    }

    @Test func changedAndMore() {
        // Two lines replaced by three: two changed, one added.
        let more = LineChanges.between(committed: committed, text: "one\nTWO\nTHREE\nextra\nfour\nfive\n")
        #expect(more.lines == [1: .modified, 2: .modified, 3: .added])
        #expect(more.summary == "2 CHANGED · 1 ADDED")
        // Three lines replaced by one: one changed, two deleted.
        let fewer = LineChanges.between(committed: committed, text: "one\nall three\nfive\n")
        #expect(fewer.lines == [1: .modified] && fewer.deleted == 2 && fewer.deletedBefore == [2])
        #expect(fewer.summary == "1 CHANGED · 2 DELETED")
    }

    @Test func newFile() {
        let changes = LineChanges.between(committed: "", text: "a\nb\n")
        #expect(changes.lines == [0: .added, 1: .added], "a file not in the last commit: every line added")
    }

    /// The capped diff against Swift's own (minimal) one on random texts: the same number of lines
    /// kept, each pair the same line, in order.
    @Test func matchesAsSwiftsDiff() {
        var random = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let a = (0..<Int.random(in: 0...30, using: &random)).map { _ in Substring(["a", "b", "c", "d"].randomElement(using: &random)!) }
            let b = (0..<Int.random(in: 0...30, using: &random)).map { _ in Substring(["a", "b", "c", "d"].randomElement(using: &random)!) }
            guard let matched = LineChanges.matches(a, b, limit: 1_000) else { Issue.record("gave up under the cap"); return }
            let pairs = matched.enumerated().compactMap { i, j in j.map { (i, $0) } }
            let removed = b.difference(from: a).removals.count
            #expect(pairs.count == a.count - removed, "as many lines kept as the minimal diff keeps: \(a) → \(b)")
            #expect(pairs.allSatisfy { a[$0.0] == b[$0.1] }, "each pair the same line")
            #expect(zip(pairs, pairs.dropFirst()).allSatisfy { $0.1 < $1.1 }, "in order")
        }
    }

    /// Past the cap: no line-by-line matching, lines not in the commit marked, said as such.
    @Test func tooManyEdits() {
        let committed = (0..<300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let text = (0..<300).map { $0 % 2 == 0 ? "line \($0)" : "other \($0)" }.joined(separator: "\n") + "\n"
        let exact = LineChanges.between(committed: committed, text: text)
        #expect(!exact.approximate && exact.modified == 150)
        let capped = LineChanges.between(committed: committed, text: text, limit: 100)
        #expect(capped.approximate && capped.modified == 150 && capped.deleted == 0)
        #expect(capped.summary == "MANY CHANGES SINCE THE LAST COMMIT · 150 NEW LINES MARKED")
        let sorted = committed.split(separator: "\n").sorted().joined(separator: "\n") + "\n"
        let moved = LineChanges.between(committed: committed, text: sorted, limit: 100)
        #expect(moved.approximate && moved.lines.isEmpty && !moved.isEmpty, "lines only moved: nothing to mark, but not no changes")
        #expect(moved.summary == "MANY CHANGES SINCE THE LAST COMMIT")
    }

    /// A change's committed lines, and the change at a line, a notch's either side.
    @Test func hunks() {
        let changes = LineChanges.between(committed: "one\ntwo\nthree\nfour\nfive\n", text: "one\nTWO\nthree\nfive\nsix\n")
        #expect(changes.hunks == [
            .init(lines: 1..<2, committed: ["two"]),
            .init(lines: 3..<3, committed: ["four"]),
            .init(lines: 4..<5, committed: []),
        ])
        #expect(changes.hunk(at: 1)?.committed == ["two"])
        #expect(changes.hunk(at: 0) == nil)
        #expect(changes.hunk(at: 2)?.committed == ["four"] && changes.hunk(at: 3)?.committed == ["four"], "the notch between lines 3 and 4 (from 1): either line")
        #expect(changes.hunk(after: 1)?.lines == 3..<3 && changes.hunk(after: 4)?.lines == 1..<2, "next, round to the first")
        #expect(changes.hunk(before: 3)?.lines == 1..<2 && changes.hunk(before: 1)?.lines == 4..<5, "previous, round to the last")
        #expect(LineChanges.between(committed: "a\n", text: "b\n", limit: 0).hunks.isEmpty, "none past the cap")
    }

    /// Revert Change on each change in turn, last to first, gives back the committed lines, the
    /// file's last line ending as it did; with \r\n too.
    @Test func revertGivesTheCommit() {
        var random = SystemRandomNumberGenerator()
        func text(_ n: Int, _ newline: String) -> String {
            let lines = (0..<n).map { _ in ["a", "b", "c", "dd", ""].randomElement(using: &random)! }
            return lines.joined(separator: newline) + (Bool.random(using: &random) && n > 0 ? newline : "")
        }
        for newline in ["\n", "\r\n"] {
            for _ in 0..<400 {
                let committed = text(Int.random(in: 0...12, using: &random), newline)
                let current = text(Int.random(in: 0...12, using: &random), newline)
                let changes = LineChanges.between(committed: committed, text: current)
                var result = current
                for hunk in changes.hunks.reversed() {
                    let (range, replacement) = LineChanges.revert(hunk, in: result, newline: newline)
                    result = (result as NSString).replacingCharacters(in: range, with: replacement)
                }
                #expect(LineChanges.split(result) == LineChanges.split(committed), "\(committed.debugDescription) ← \(current.debugDescription): \(result.debugDescription)")
                let ended = current.hasSuffix(newline) || current.isEmpty, ends = result.hasSuffix(newline) || result.isEmpty
                #expect(ended == ends || LineChanges.split(committed).isEmpty || LineChanges.split(committed).last == "",
                        "the last line ends as it did (but an empty last line has its newline): \(current.debugDescription) → \(result.debugDescription)")
                #expect(newline == "\n" || !result.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare \\n in a \\r\\n file: \(result.debugDescription)")
            }
        }
    }

    /// One change reverted alone: only its lines change.
    @Test func revertOne() {
        let current = "one\nTWO\nthree\nfive\nsix"
        let changes = LineChanges.between(committed: "one\ntwo\nthree\nfour\nfive\n", text: current)
        func apply(_ i: Int) -> String {
            let (range, replacement) = LineChanges.revert(changes.hunks[i], in: current)
            return (current as NSString).replacingCharacters(in: range, with: replacement)
        }
        #expect(apply(0) == "one\ntwo\nthree\nfive\nsix")
        #expect(apply(1) == "one\nTWO\nthree\nfour\nfive\nsix")
        #expect(apply(2) == "one\nTWO\nthree\nfive", "an added last line out, with the newline before it")
    }
}
