// Changes since the last commit (PRD ED12): lines added, changed and deleted, as the gutter marks them.

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
}
