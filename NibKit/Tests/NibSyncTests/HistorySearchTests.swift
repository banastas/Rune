// Find in History (PRD SY18): the newest version with a match, the find bar's options, each
// version read once, and a stop when the query changes.

import Foundation
import NibText
import Testing

@testable import NibSync

@Suite struct HistorySearchTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Versions oldest first, as History lists them; the same text twice is the same SHA.
    func entries(_ texts: [String]) -> ([HistoryEntry], [String: String]) {
        var byHash: [String: String] = [:], list: [HistoryEntry] = []
        for (i, text) in texts.enumerated() {
            let sha = Digest.sha256(Data(text.utf8))
            byHash[sha] = text
            list.append(HistoryEntry(sha256: sha, parent: nil, time: start.addingTimeInterval(Double(i) * 300), source: "saved", size: text.utf8.count))
        }
        return (list, byHash)
    }

    @Test func newestVersionFirst() {
        let (list, texts) = entries(["a lost line\nmore", "a lost line, edited\nmore", "more"])
        let outcome = HistorySearch.newest("lost line", options: SearchOptions(), in: list, load: { texts[$0] })
        guard case .found(let entry, let matches) = outcome else { Issue.record("not found: \(outcome)"); return }
        #expect(entry == list[1], "the newest version that still had it")
        #expect(matches == [NSRange(location: 2, length: 9)])
    }

    @Test func theBarsOptions() {
        let (list, texts) = entries(["Passport and tickets", "passports"])
        let caseOn = HistorySearch.newest("passport", options: SearchOptions(matchCase: true), in: list, load: { texts[$0] })
        let whole = HistorySearch.newest("passport", options: SearchOptions(wholeWord: true), in: list, load: { texts[$0] })
        let regex = HistorySearch.newest("pass\\w+ and", options: SearchOptions(regex: true), in: list, load: { texts[$0] })
        let bad = HistorySearch.newest("pass(", options: SearchOptions(regex: true), in: list, load: { texts[$0] })
        if case .found(let entry, _) = caseOn { #expect(entry == list[1]) } else { Issue.record("match case: \(caseOn)") }
        if case .found(let entry, _) = whole { #expect(entry == list[0], "“passports” isn't the whole word") } else { Issue.record("whole word: \(whole)") }
        if case .found(let entry, _) = regex { #expect(entry == list[0]) } else { Issue.record("regex: \(regex)") }
        #expect(bad == .badPattern)
    }

    @Test func eachVersionReadOnce() {
        let (list, texts) = entries(["one", "two", "one", "two", "three"])
        var reads: [String] = []
        let outcome = HistorySearch.newest("nowhere", options: SearchOptions(), in: list, load: { reads.append($0); return texts[$0] })
        #expect(outcome == .nowhere(searched: 3))
        #expect(reads.count == 3, "a version back again isn't read twice")
    }

    @Test func stopsWhenCancelled() {
        let (list, texts) = entries(["a", "b", "c", "d"])
        var reads = 0
        let outcome = HistorySearch.newest("z", options: SearchOptions(), in: list, load: { reads += 1; return texts[$0] }, isCancelled: { reads >= 2 })
        #expect(outcome == .cancelled)
        #expect(reads == 2)
    }

    @Test func unreadableVersionsSkipped() {
        let (list, texts) = entries(["kept text", "gone"])
        let outcome = HistorySearch.newest("kept", options: SearchOptions(), in: list, load: { $0 == list[1].sha256 ? nil : texts[$0] })
        if case .found(let entry, _) = outcome { #expect(entry == list[0]) } else { Issue.record("\(outcome)") }
    }
}
