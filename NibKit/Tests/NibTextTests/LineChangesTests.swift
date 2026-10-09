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
}
