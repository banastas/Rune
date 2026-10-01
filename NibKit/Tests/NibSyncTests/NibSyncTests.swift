// The save path's promises (PRD §4.1-4.3): the journal survives and rejects damage,
// saves are compare-and-swap and never overwrite a version they haven't seen, saving
// keeps the file itself (inode, permissions), and the save schedule's timing.

import Darwin
import Foundation
import Testing

@testable import NibSync
@testable import NibText

func scratchFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nibkit-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct JournalTests {
    @Test func writeReadClear() throws {
        let journal = Journal(directory: scratchFolder())
        let entry = JournalEntry(path: "/tmp/a.md", text: "typed\n", baseSHA256: "abc", format: .standard)
        try journal.write(entry)
        #expect(journal.read(path: "/tmp/a.md")?.text == "typed\n")
        #expect(journal.read(path: "/tmp/other.md") == nil)
        journal.clear(path: "/tmp/a.md")
        #expect(journal.read(path: "/tmp/a.md") == nil)
    }

    @Test func latestSnapshotWins() throws {
        let journal = Journal(directory: scratchFolder())
        for n in 1...5 {
            try journal.write(JournalEntry(path: "/tmp/a.md", text: "v\(n)", baseSHA256: nil, format: .standard))
        }
        #expect(journal.read(path: "/tmp/a.md")?.text == "v5")
    }

    @Test func damagedSnapshotIsIgnored() throws {
        let journal = Journal(directory: scratchFolder())
        var entry = JournalEntry(path: "/tmp/a.md", text: "good", baseSHA256: nil, format: .standard)
        entry.text = "tampered"   // textSHA256 still describes "good"
        try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: journal.url(for: "/tmp/a.md"))
        #expect(journal.read(path: "/tmp/a.md") == nil)
    }
}

@Suite struct FileAccessTests {
    @Test func createsANewFile() throws {
        let url = scratchFolder().appendingPathComponent("new.md")
        let outcome = try FileAccess.write(Data("hello\n".utf8), to: url, base: nil)
        guard case .written(let fingerprint) = outcome else { Issue.record("not written"); return }
        #expect(try Data(contentsOf: url) == Data("hello\n".utf8))
        #expect(fingerprint.sha256 == Digest.sha256(Data("hello\n".utf8)))
    }

    @Test func savesInPlaceKeepingInodeAndPermissions() throws {
        let url = scratchFolder().appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho one\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        let (_, base) = try FileAccess.read(url)
        let outcome = try FileAccess.write(Data("#!/bin/sh\necho two, longer\n".utf8), to: url, base: base)
        guard case .written(let after) = outcome else { Issue.record("not written"); return }
        #expect(after.fileID == base.fileID)
        var info = stat()
        lstat(url.path, &info)
        #expect(info.st_mode & 0o777 == 0o755)
        #expect(try String(contentsOf: url, encoding: .utf8) == "#!/bin/sh\necho two, longer\n")
    }

    @Test func shorterContentsAreTruncated() throws {
        let url = scratchFolder().appendingPathComponent("a.md")
        try Data("a long first version\n".utf8).write(to: url)
        let (_, base) = try FileAccess.read(url)
        _ = try FileAccess.write(Data("short\n".utf8), to: url, base: base)
        #expect(try String(contentsOf: url, encoding: .utf8) == "short\n")
    }

    @Test func neverOverwritesAVersionItHasntSeen() throws {
        let url = scratchFolder().appendingPathComponent("a.md")
        try Data("base\n".utf8).write(to: url)
        let (_, base) = try FileAccess.read(url)
        // Another Mac (or app) writes a new version after nib loaded the base.
        Thread.sleep(forTimeInterval: 0.01)
        try Data("theirs\n".utf8).write(to: url)
        let outcome = try FileAccess.write(Data("mine\n".utf8), to: url, base: base)
        guard case .diskChanged(let data, let fingerprint) = outcome else { Issue.record("overwrote it"); return }
        #expect(data == Data("theirs\n".utf8))
        #expect(fingerprint.sha256 == Digest.sha256(Data("theirs\n".utf8)))
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")
    }

    @Test func aTouchWithTheSameBytesIsNotAChange() throws {
        let url = scratchFolder().appendingPathComponent("a.md")
        try Data("same\n".utf8).write(to: url)
        let (_, base) = try FileAccess.read(url)
        Thread.sleep(forTimeInterval: 0.01)
        try Data("same\n".utf8).write(to: url)   // new modification time, same contents
        let outcome = try FileAccess.write(Data("mine\n".utf8), to: url, base: base)
        guard case .written = outcome else { Issue.record("treated as a change"); return }
        #expect(try String(contentsOf: url, encoding: .utf8) == "mine\n")
    }

    @Test func aDeletedFileIsNotRecreatedSilently() throws {
        let url = scratchFolder().appendingPathComponent("a.md")
        try Data("base\n".utf8).write(to: url)
        let (_, base) = try FileAccess.read(url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: CocoaError.self) { try FileAccess.write(Data("mine\n".utf8), to: url, base: base) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anUnexpectedFileIsNotOverwritten() throws {
        let url = scratchFolder().appendingPathComponent("a.md")
        try Data("appeared\n".utf8).write(to: url)
        let outcome = try FileAccess.write(Data("mine\n".utf8), to: url, base: nil)
        guard case .diskChanged = outcome else { Issue.record("overwrote it"); return }
    }
}

@Suite struct ScheduleAndRecordTests {
    @Test func saveIsDueAfterAPauseOrTheMaximumWait() {
        var schedule = SaveSchedule(idle: 1, maxWait: 5)
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(schedule.due == nil)
        schedule.edited(at: t0)
        #expect(schedule.due == t0.addingTimeInterval(1))
        // Continuous typing: every keystroke pushes the idle deadline, but not past 5 s.
        for n in 1...20 { schedule.edited(at: t0.addingTimeInterval(Double(n) * 0.3)) }
        #expect(schedule.due == t0.addingTimeInterval(5))
        schedule.saved()
        #expect(schedule.due == nil)
    }

    @Test func pausedFilesList() {
        let list = PausedFiles(url: scratchFolder().appendingPathComponent("paused.json"))
        list.add("/a")
        list.add("/b")
        list.add("/a")
        #expect(list.all() == ["/a", "/b"])
        list.remove("/a")
        #expect(list.all() == ["/b"])
    }

    @Test func syncLogAppends() {
        let log = SyncLog(url: scratchFolder().appendingPathComponent("sync.jsonl"))
        log.append(SyncEvent("save", path: "/a", device: "Air", size: 4))
        log.append(SyncEvent("upload", path: "/a", device: "Air", ms: 2200))
        #expect(log.read().map(\.event) == ["save", "upload"])
    }

    @Test func conflictErrorIsRecognized() {
        let underlying = NSError(domain: "NSFileProviderErrorDomain", code: -2015)
        let error = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(CloudControl.isConflict(error))
        #expect(!CloudControl.isConflict(NSError(domain: NSCocoaErrorDomain, code: 4355)))
    }
}

@Suite struct AnnouncementTests {
    @Test func livesInAHiddenFolderBesideTheFile() {
        let doc = URL(fileURLWithPath: "/tmp/icloud/_scratch2.md")
        #expect(Announcement.url(for: doc).path == "/tmp/icloud/.nib/latest-_scratch2.md.json")
    }

    @Test func roundTrip() throws {
        let doc = scratchFolder().appendingPathComponent("scratch.md")
        let note = Announcement(sha256: "abc", parent: "def", device: "Mac mini", time: Date(timeIntervalSince1970: 1_790_000_000), size: 42)
        try note.write(for: doc)
        #expect(Announcement.read(for: doc) == note)
    }

    @Test func missingMeansNone() {
        #expect(Announcement.read(for: scratchFolder().appendingPathComponent("none.md")) == nil)
    }
}

@Suite struct TimeLimitTests {
    @Test func givesUpOnACallThatNeverAnswers() async {
        let start = Date()
        await #expect(throws: CloudControl.ControlError.self) {
            try await CloudControl.within(0.2) { try await Task.sleep(for: .seconds(30)); return 1 }
        }
        #expect(Date().timeIntervalSince(start) < 2)   // didn't wait for the abandoned call
    }

    @Test func passesThroughAQuickAnswer() async throws {
        #expect(try await CloudControl.within(2) { 7 } == 7)
    }

    @Test func passesThroughAnError() async {
        await #expect(throws: CocoaError.self) {
            try await CloudControl.within(2) { () -> Int in throw CocoaError(.fileReadUnknown) }
        }
    }
}

@Suite struct HistoryTests {
    @Test func keepsEachVersionOnceAndListsWhereItCameFrom() throws {
        let history = History(root: scratchFolder(), path: "/tmp/scratch.md")
        try history.record(Data("one\n".utf8), parent: nil, source: "saved")
        try history.record(Data("one\n".utf8), parent: nil, source: "saved")        // the same again: not a new entry
        try history.record(Data("two\n".utf8), parent: Digest.sha256(Data("one\n".utf8)), source: "from Air")
        try history.record(Data("one\n".utf8), parent: nil, source: "duplicate scratch 2.md")   // back again: an entry, one copy
        let entries = history.entries()
        #expect(entries.map(\.source) == ["saved", "from Air", "duplicate scratch 2.md"])
        #expect(history.data(Digest.sha256(Data("two\n".utf8))) == Data("two\n".utf8))
        #expect(history.contains(Digest.sha256(Data("one\n".utf8))))
        #expect(!history.contains(Digest.sha256(Data("three\n".utf8))))
    }

    @Test func thinsByAge() throws {
        let history = History(root: scratchFolder(), path: "/tmp/scratch.md")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func at(_ hoursAgo: Double, _ text: String) throws {
            try history.record(Data(text.utf8), parent: nil, source: "saved", time: now.addingTimeInterval(-hoursAgo * 3_600))
        }
        try at(40 * 24, "too old")                            // over 30 days: gone
        // Buckets are clock hours and UTC days; `now` is 33 min into an hour, 3 h 33 min into a day.
        try at(10 * 24 + 2.5, "day 10, early"); try at(10 * 24 + 0.5, "day 10, late")   // one a day: the later
        try at(3 * 24 + 0.3, "day 3, hour a"); try at(3 * 24 + 0.1, "day 3, hour a, later")   // one an hour: the later
        try at(2, "today 1"); try at(1, "today 2")            // the last day: all
        history.thin(now: now)
        #expect(history.entries().map { String(decoding: history.data($0.sha256) ?? Data(), as: UTF8.self) }
                == ["day 10, late", "day 3, hour a, later", "today 1", "today 2"])
        #expect(!history.contains(Digest.sha256(Data("too old".utf8))))   // its bytes went too
        // Let go, a version is still one this Mac had (receipts, SY14), for History's 30 days.
        let thinned = Digest.sha256(Data("day 3, hour a".utf8))
        #expect(!history.contains(thinned) && history.has(thinned))
        #expect(!history.has(Digest.sha256(Data("too old".utf8))))
        #expect(!history.has(Digest.sha256(Data("never here".utf8))))
        history.thin(now: now.addingTimeInterval(28 * 86_400))   // day 3 is 31 days old then
        #expect(!history.has(thinned))
    }
}

@Suite struct DuplicateTests {
    @Test func namesICloudGives() {
        #expect(Duplicates.isDuplicate("scratch 2.md", of: "scratch.md"))
        #expect(Duplicates.isDuplicate("scratch 10.md", of: "scratch.md"))
        #expect(Duplicates.isDuplicate("scratch-test 2.md", of: "scratch-test.md"))
        #expect(Duplicates.isDuplicate("my notes 3.md", of: "my notes.md"))
        #expect(Duplicates.isDuplicate("notes 2", of: "notes"))
    }

    @Test func namesThatAreNotDuplicates() {
        for name in ["scratch 1.md", "scratch 2.txt", "scratch copy.md", "scratch2.md", "scratch 2 2.md",
                     "scratch .md", "scratch 02.md", "scratch ２.md", "other 2.md", "scratch.md"] {
            #expect(!Duplicates.isDuplicate(name, of: "scratch.md"), "\(name)")
        }
    }

    @Test func findsThemBesideTheFile() throws {
        let folder = scratchFolder()
        for name in ["scratch.md", "scratch 2.md", "scratch 3.md", "scratch copy.md", "notes 2.md"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
        }
        #expect(Duplicates.beside(folder.appendingPathComponent("scratch.md")).map(\.lastPathComponent) == ["scratch 2.md", "scratch 3.md"])
    }
}

/// The Sync Log window's words, glyphs, filters and search (SY13, A13, V3, V4), on the
/// details Document actually writes.
@Suite struct SyncLogDisplayTests {
    func event(_ name: String, detail: String? = nil, sha: String? = nil) -> SyncEvent {
        SyncEvent(name, path: "/iCloud/Nib/scratch.md", device: "Air", sha256: sha, detail: detail)
    }

    @Test func wordsAndGlyphs() {
        #expect(event("save").word == "Saved" && event("save").glyph == "=")
        #expect(event("upload", sha: "ab").word == "Uploaded" && event("upload", sha: "ab").glyph == "▲")
        let refused = event("upload", detail: "refused: the server has a newer version")
        #expect(refused.word == "Upload refused" && refused.glyph == "‖" && !refused.failed && refused.needsLook)
        let failed = event("upload", detail: "failed: The operation couldn't be completed")
        #expect(failed.word == "Upload failed" && failed.glyph == "✕" && failed.failed)
        #expect(event("upload", detail: "no answer in 15 s; retrying").word == "Upload unanswered")
        #expect(event("fetch", detail: "newer, saved by Studio (open)").glyph == "▼")
        #expect(event("merge").word == "Merged" && event("merge").glyph == "✓")
        #expect(event("conflict", detail: "merged from the version both had, 1 place between markers").glyph == "✕")
        #expect(event("problem", detail: "the file was deleted or moved away").failed)
        #expect(event("pause").word == "Held" && event("pause", detail: "not offered: iCloud uploads on its own schedule").word == "Not held")
        #expect(event("pause", detail: "failed, running unheld: x").failed)
        let notYet = event("pause", detail: "not held yet: NSCocoaErrorDomain 4099; trying again in 2 s")
        #expect(notYet.word == "Not held" && notYet.glyph == "‖" && !notYet.failed && notYet.needsLook)
        #expect(event("pause", detail: "held on try 3").word == "Held" && event("pause", detail: "held on try 3").glyph == "·")
        #expect(event("pause", detail: "still failing after 6 tries: running unheld, trying every minute while it's open").glyph == "✕")
        #expect(event("resume").word == "Handed back" && event("quit").word == "Closed")
        #expect(event("merge view").word == "Merge view" && event("something new").word == "Something new")
    }

    @Test func filters() {
        let lines = [event("save"), event("upload", sha: "ab"), event("fetch"), event("merge"), event("conflict"),
                     event("problem", detail: "save: disk full"), event("upload", detail: "refused: the server has a newer version")]
        func names(_ filter: SyncEvent.Category) -> [String] { lines.filter { $0.belongs(to: filter) }.map(\.word) }
        #expect(names(.all).count == lines.count)
        #expect(names(.saves) == ["Saved", "Uploaded", "Upload refused"])
        #expect(names(.arrivals) == ["Fetched", "Merged", "Conflict"])
        #expect(names(.problems) == ["Conflict", "Problem", "Upload refused"])
    }

    @Test func search() {
        let line = SyncEvent("fetch", path: "/iCloud/Nib/notes.md", device: "Studio", sha256: "7cfab3c0deadbeef", detail: "newer, saved by Air (activated)")
        #expect(line.matches(""))
        #expect(line.matches("notes"))
        #expect(line.matches("NOTES.MD air"))       // every word, any field, any case
        #expect(line.matches("fetched"))
        #expect(line.matches("7cfab3"))             // the SHA-256 from its start
        #expect(!line.matches("fab3c0") && !line.matches("scratch"))
    }

    @Test func appendingIsAnnounced() async {
        let log = SyncLog(url: scratchFolder().appendingPathComponent("sync.jsonl"))
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(forName: SyncLog.didAppend, object: nil, queue: nil) { _ in counter.bump() }
        defer { NotificationCenter.default.removeObserver(observer) }
        log.append(SyncEvent("save", path: "/a", device: "Air"))
        #expect(counter.value >= 1)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
