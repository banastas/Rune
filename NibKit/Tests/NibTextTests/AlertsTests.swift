// Notifications (PRD SY15, A8): each problem once while it lasts, per file, never while Nib is
// frontmost, and in the strip's words as sentences.

import Testing

@testable import NibText

@Suite struct AlertsTests {
    @Test func oncePerEpisode() {
        var ledger = AlertLedger()
        let first = ledger.began(.storageFull, file: "/a", frontmost: false)
        let retry = ledger.began(.storageFull, file: "/a", frontmost: false)
        let other = ledger.began(.conflict, file: "/a", frontmost: false)
        let otherFile = ledger.began(.storageFull, file: "/b", frontmost: false)
        let over = ledger.ended(.storageFull, file: "/a")
        let overAgain = ledger.ended(.storageFull, file: "/a")
        let back = ledger.began(.storageFull, file: "/a", frontmost: false)
        #expect(first, "said when it begins")
        #expect(!retry, "not again on a retry while it lasts")
        #expect(other, "another problem, its own")
        #expect(otherFile, "another file, its own")
        #expect(over, "over: it went out, so it's taken back")
        #expect(!overAgain, "over once")
        #expect(back, "back again after it ended: said again")
    }

    @Test func notWhileFrontmost() {
        var ledger = AlertLedger()
        let inFront = ledger.began(.saveFailed, file: "/a", frontmost: true)
        let later = ledger.began(.saveFailed, file: "/a", frontmost: false)
        let ongoing = ledger.isOngoing(.saveFailed, file: "/a")
        let takenBack = ledger.ended(.saveFailed, file: "/a")
        let next = ledger.began(.saveFailed, file: "/a", frontmost: false)
        #expect(!inFront, "the strip says it there")
        #expect(!later, "seen, so not said later while it lasts")
        #expect(ongoing)
        #expect(!takenBack, "nothing went out to take back")
        #expect(next, "and next time it's news")
    }

    @Test func closingEndsAll() {
        var ledger = AlertLedger()
        _ = ledger.began(.deleted, file: "/a", frontmost: false)
        _ = ledger.began(.conflict, file: "/a", frontmost: true)
        let said = ledger.closed("/a")
        let conflictGone = !ledger.isOngoing(.conflict, file: "/a")
        let fresh = ledger.began(.deleted, file: "/a", frontmost: false)
        #expect(said == [.deleted], "what went out, to take back")
        #expect(conflictGone && fresh)
    }

    @Test func words() {
        let conflict = Alerts.conflict("scratch.md", with: "Air", places: 1)
        #expect(conflict.title == "Conflict with Air in scratch.md" && conflict.body.hasPrefix("In 1 place: both versions are in the text"))
        #expect(Alerts.conflict("scratch.md", with: "Air", places: 3).body.hasPrefix("In 3 places: both versions of each"))
        // ⌘3 keeps both, not one (the QA review's F8).
        #expect(conflict.body.hasSuffix("⌘1 or ⌘2 in the block keeps one version, ⌘3 keeps both.") && !conflict.body.contains("⌘3 keeps one"))
        let failed = Alerts.saveFailed("notes.md", why: "NO PERMISSION")
        #expect(failed.kind == .saveFailed && failed.body == "No permission. Your text is in Nib's recovery journal, and Nib keeps trying.")
        #expect(Alerts.saveFailed("notes.md", why: "The volume is read-only.").body.hasPrefix("The volume is read-only. Your text"))
        #expect(Alerts.diskFull("scratch.md").body.contains("only in memory") && Alerts.diskFull("scratch.md").kind == .saveFailed)
        #expect(Alerts.deleted("a.md", trash: true).title == "a.md was moved to the Trash" && Alerts.deleted("a.md", trash: false).title == "a.md was deleted")
        #expect(Alerts.iCloudOff("a.md").body.hasPrefix("a.md went with it.") && Alerts.storageFull("a.md").body.hasPrefix("a.md is saved on this Mac only"))
        #expect(Alerts.journalFailed("a.md", why: "I/O ERROR").title == "Couldn't write Nib's recovery journal")
    }
}
