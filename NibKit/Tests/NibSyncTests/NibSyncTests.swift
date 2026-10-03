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

    /// A big text (§4.3, §4.9 row 24): one snapshot, then only the changes, appended.
    static let big: String = {
        var text = "# Scratch\n", n = 0
        while text.utf16.count < 1_200_000 { n += 1; text += "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
        return text
    }()

    @Test func bigTextsLogTheirEdits() throws {
        let journal = Journal(directory: scratchFolder())
        var text = Self.big
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        try journal.record(path: "/tmp/big.md", text: text, baseSHA256: "v1", format: .standard, now: start)
        let snapshot = try Data(contentsOf: journal.url(for: "/tmp/big.md"))
        var seed: UInt64 = 41
        func next() -> Int {   // a seeded generator, so a failure can be replayed
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        for step in 1...30 {
            let ns = text as NSString
            var at = next() % ns.length
            if at > 0, UTF16.isTrailSurrogate(ns.character(at: at)) { at -= 1 }
            let cut = min(next() % 6, ns.length - at)
            text = ns.replacingCharacters(in: NSRange(location: at, length: cut), with: ["x", "", "🙂", "word ", "\n"][step % 5])
            try journal.record(path: "/tmp/big.md", text: text, baseSHA256: "v1", format: .standard, now: start.addingTimeInterval(Double(step)))
        }
        #expect(journal.read(path: "/tmp/big.md")?.text == text)
        #expect(try Data(contentsOf: journal.url(for: "/tmp/big.md")) == snapshot, "the snapshot isn't written again")
        let log = journal.logBytes(for: "/tmp/big.md")
        #expect(log < 8_000, "30 edits in \(log) bytes")
        // Read anew, as the next launch does.
        #expect(Journal(directory: journal.directory).read(path: "/tmp/big.md")?.text == text)
    }

    @Test func aTornLineIsIgnored() throws {
        let journal = Journal(directory: scratchFolder())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        try journal.record(path: "/tmp/big.md", text: Self.big, baseSHA256: nil, format: .standard, now: start)
        let one = Self.big + "one\n", two = one + "two\n"
        try journal.record(path: "/tmp/big.md", text: one, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(1))
        try journal.record(path: "/tmp/big.md", text: two, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(2))
        let url = journal.logURL(for: "/tmp/big.md")
        var log = try Data(contentsOf: url)
        let end = journal.logBytes(for: "/tmp/big.md")
        log.replaceSubrange(end - 9 ..< end, with: Data(count: 9))   // a crash partway through the last line: its end never written
        try log.write(to: url)
        #expect(journal.read(path: "/tmp/big.md")?.text == one)
    }

    @Test func aBigTextsCleanSaveLeavesNothingToRecover() throws {
        let journal = Journal(directory: scratchFolder())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        try journal.record(path: "/tmp/big.md", text: Self.big, baseSHA256: "v1", format: .standard, now: start)
        try journal.record(path: "/tmp/big.md", text: Self.big + "typed\n", baseSHA256: "v1", format: .standard, now: start.addingTimeInterval(1))
        journal.clear(path: "/tmp/big.md")
        #expect(journal.read(path: "/tmp/big.md") == nil)
        #expect(FileManager.default.fileExists(atPath: journal.url(for: "/tmp/big.md").path), "the snapshot stays, for the next change")
        // The save's version is the base from now on; the next typing is journaled again.
        try journal.record(path: "/tmp/big.md", text: Self.big + "typed\nmore\n", baseSHA256: "v2", format: .standard, now: start.addingTimeInterval(2))
        let entry = journal.read(path: "/tmp/big.md")
        #expect(entry?.text == Self.big + "typed\nmore\n" && entry?.baseSHA256 == "v2")
    }

    /// Not after a minute any more (150 MB an hour of typing at 2.4 MB, 2026-10-02): once the log
    /// has a megabyte of lines.
    @Test func aSnapshotOnceTheLogIsFull() throws {
        let journal = Journal(directory: scratchFolder())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        try journal.record(path: "/tmp/big.md", text: Self.big, baseSHA256: nil, format: .standard, now: start)
        let first = try Data(contentsOf: journal.url(for: "/tmp/big.md"))
        try journal.record(path: "/tmp/big.md", text: Self.big + "a\n", baseSHA256: nil, format: .standard, now: start.addingTimeInterval(3_600))
        #expect(try Data(contentsOf: journal.url(for: "/tmp/big.md")) == first, "an hour later, still a line")
        let pasted = String(repeating: "pasted text, a long paragraph of it\n", count: 15_000)   // 540 KB a line
        var text = Self.big + "a\n"
        for n in 1...2 {
            text += pasted
            try journal.record(path: "/tmp/big.md", text: text, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(3_600 + Double(n)))
            #expect(try Data(contentsOf: journal.url(for: "/tmp/big.md")) == first, "the log takes the paste")
        }
        text += "b\n"
        try journal.record(path: "/tmp/big.md", text: text, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(3_610))
        #expect(try Data(contentsOf: journal.url(for: "/tmp/big.md")) != first, "a new snapshot once the log is over a megabyte")
        #expect(journal.logBytes(for: "/tmp/big.md") < 200, "and a new log")
        #expect(journal.read(path: "/tmp/big.md")?.text == text)
    }

    @Test func theBaseMovesWithASave() throws {
        let journal = Journal(directory: scratchFolder())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        try journal.record(path: "/tmp/big.md", text: Self.big + "x\n", baseSHA256: "v1", format: .standard, now: start)
        try journal.record(path: "/tmp/big.md", text: Self.big + "x\n", baseSHA256: "v2", format: .standard, now: start.addingTimeInterval(1))
        #expect(journal.read(path: "/tmp/big.md")?.baseSHA256 == "v2")
    }

    /// A small text logs its edits too (a whole snapshot each pause of a 223 KB scratch file was
    /// a gigabyte or two an hour, 2026-10-02), and the lines go into room the log already has.
    @Test func smallTextsLogTheirEditsToo() throws {
        let journal = Journal(directory: scratchFolder())
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var text = "small\n"
        try journal.record(path: "/tmp/a.md", text: text, baseSHA256: nil, format: .standard, now: start)
        let snapshot = try Data(contentsOf: journal.url(for: "/tmp/a.md"))
        let size = { (try? FileManager.default.attributesOfItem(atPath: journal.logURL(for: "/tmp/a.md").path)[.size] as? Int) ?? 0 }
        let room = size()
        for n in 1...20 {
            text += "line \(n)\n"
            try journal.record(path: "/tmp/a.md", text: text, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(Double(n)))
        }
        #expect(try Data(contentsOf: journal.url(for: "/tmp/a.md")) == snapshot, "one snapshot")
        #expect(size() == room && journal.logBytes(for: "/tmp/a.md") > 20 * 40, "twenty lines in the room it had")
        #expect(Journal(directory: journal.directory).read(path: "/tmp/a.md")?.text == text)
        // A text grown past the room: more is made, and it all reads back.
        let big = text + String(repeating: "more typing\n", count: 8_000)
        try journal.record(path: "/tmp/a.md", text: big, baseSHA256: nil, format: .standard, now: start.addingTimeInterval(30))
        try journal.record(path: "/tmp/a.md", text: big + "end\n", baseSHA256: nil, format: .standard, now: start.addingTimeInterval(31))
        #expect(size() > room && Journal(directory: journal.directory).read(path: "/tmp/a.md")?.text == big + "end\n")
        journal.clear(path: "/tmp/a.md")
        #expect(journal.read(path: "/tmp/a.md") == nil)
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
        guard case .written(let fingerprint, _) = outcome else { Issue.record("not written"); return }
        #expect(try Data(contentsOf: url) == Data("hello\n".utf8))
        #expect(fingerprint.sha256 == Digest.sha256(Data("hello\n".utf8)))
    }

    @Test func savesInPlaceKeepingInodeAndPermissions() throws {
        let url = scratchFolder().appendingPathComponent("script.sh")
        try Data("#!/bin/sh\necho one\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        let (_, base) = try FileAccess.read(url)
        let outcome = try FileAccess.write(Data("#!/bin/sh\necho two, longer\n".utf8), to: url, base: base)
        guard case .written(let after, _) = outcome else { Issue.record("not written"); return }
        #expect(after.fileID == base.fileID)
        var info = stat()
        lstat(url.path, &info)
        #expect(info.st_mode & 0o777 == 0o755)
        #expect(try String(contentsOf: url, encoding: .utf8) == "#!/bin/sh\necho two, longer\n")
    }

    /// Only what changed is written (2026-10-02, PRD §8): typing at the end of a big file wrote
    /// all of it at every save.
    @Test func aSaveWritesOnlyWhatChanged() throws {
        let url = scratchFolder().appendingPathComponent("big.md")
        var text = Data(JournalTests.big.utf8)   // 1.2 MB: the comparison crosses its megabyte chunks
        try text.write(to: url)
        let inode = try FileAccess.stat(url).fileID
        func save(_ data: Data) throws -> Int {
            let written = try FileAccess.overwriteInPlace(url, with: data)
            #expect(try Data(contentsOf: url) == data)
            return written
        }
        text += Data("typed at the end\n".utf8)
        #expect(try save(text) == 17, "the end: what was typed")
        text.replaceSubrange(1_100_000 ..< 1_100_004, with: Data("WXYZ".utf8))
        #expect(try save(text) <= 4, "the same length: the bytes that differ")
        text.replaceSubrange(1_000 ..< 1_000, with: Data("inserted near the top\n".utf8))
        #expect(try save(text) == text.count - 1_000, "near the top: from there to the end")
        text.removeLast(9)
        #expect(try save(text) == 0, "cut at the end: nothing written, only shortened")
        let modified = try FileAccess.stat(url).modified
        Thread.sleep(forTimeInterval: 0.01)
        #expect(try save(text) == 0 && FileAccess.stat(url).modified == modified, "the same bytes: the file isn't touched")
        #expect(try FileAccess.stat(url).fileID == inode, "the same file throughout")
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

    /// A save that wrote much holds the next back (2026-10-02, the user's call): 2.4 MB at 80 KB/s
    /// is 30 s; a kilobyte at the end of a file isn't noticed.
    @Test func aBigSaveHoldsTheNextBack() {
        var schedule = SaveSchedule(idle: 1, maxWait: 5)
        let t0 = Date(timeIntervalSince1970: 1000)
        schedule.wrote(2_400_000, at: t0)
        schedule.saved()
        schedule.edited(at: t0.addingTimeInterval(1))
        #expect(schedule.due == t0.addingTimeInterval(30), "near the top of 2.4 MB: 30 s after the last save")
        schedule.wrote(1_000, at: t0.addingTimeInterval(30))
        schedule.saved()
        schedule.edited(at: t0.addingTimeInterval(31))
        #expect(schedule.due == t0.addingTimeInterval(32), "a kilobyte: a second after the pause, as ever")
        var off = SaveSchedule(idle: 1, maxWait: 5, rate: 0)
        off.wrote(2_400_000, at: t0)
        off.edited(at: t0)
        #expect(off.due == t0.addingTimeInterval(1), "no rate, no hold")
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

    @Test func aSaveNotKeptIsStillOneThisMacHad() throws {
        // Open question 22: the saves between History's five-minute ones keep no copy, but a
        // receipt naming one isn't news (SY14), for History's 30 days, through thinning.
        let history = History(root: scratchFolder(), path: "/tmp/scratch.md")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let skipped = Digest.sha256(Data("skipped".utf8)), old = Digest.sha256(Data("old".utf8))
        history.noteSeen(old, time: now.addingTimeInterval(-31 * 86_400))
        history.noteSeen(skipped, time: now.addingTimeInterval(-60))
        history.noteSeen(skipped, time: now)
        try history.record(Data("kept".utf8), parent: nil, source: "saved", time: now)
        #expect(!history.contains(skipped) && history.has(skipped) && history.has(old))
        #expect(!history.has(Digest.sha256(Data("never here".utf8))))
        history.thin(now: now)
        #expect(history.has(skipped) && !history.has(old))   // 31 days old: gone
        let lines = try String(contentsOf: history.directory.appendingPathComponent("thinned.txt"), encoding: .utf8)
        #expect(lines.split(separator: "\n").count == 1)   // seen twice: one line, its latest time
        #expect(history.entries().count == 1)
        history.thin(now: now.addingTimeInterval(31 * 86_400))
        #expect(!history.has(skipped))
    }

    @Test func anOpenFileThinnedOnceADay() throws {
        // The scratch file stays open for days (SC1), so its History is thinned once a day while
        // it is (PRD §8, 2026-10-02): all of the last day, then the newest of each hour to a week,
        // the newest of each day to 30 days. Most of those thins have nothing due, and write nothing.
        let history = History(root: scratchFolder(), path: "/tmp/scratch.md")
        let midnight = Date(timeIntervalSince1970: 1_999_987_200)   // UTC, as the buckets are
        func at(_ days: Double, _ hours: Double) -> Date { midnight.addingTimeInterval(days * 86_400 + hours * 3_600) }
        // Day 0, 09:00-10:55: a save kept every 5 minutes, each noted as seen, as the document does.
        let saves = (0..<24).map { Data("save \($0)".utf8) }
        for (k, data) in saves.enumerated() {
            history.noteSeen(Digest.sha256(data), time: at(0, 9 + Double(k) / 12))
            try history.record(data, parent: nil, source: "saved", time: at(0, 9 + Double(k) / 12))
        }
        let files = ["index.jsonl", "thinned.txt"].map { history.directory.appendingPathComponent($0) }
        func written() throws -> [Int] {   // each file's inode: a rewrite replaces the file
            try files.map { try #require(FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? Int) }
        }
        func kept() -> [Data] { history.entries().compactMap { history.data($0.sha256) } }

        let before = try written()
        #expect(!history.thin(now: at(0, 12)))   // all within a day
        #expect(try written() == before && kept() == saves)

        #expect(history.thin(now: at(1, 12)))   // a day old: each hour's newest
        #expect(kept() == [saves[11], saves[23]])
        #expect(saves.allSatisfy { history.has(Digest.sha256($0)) })   // the rest still had here (receipts)
        #expect(!history.contains(Digest.sha256(saves[0])))   // their bytes gone

        let thinned = try written()
        #expect(!history.thin(now: at(2, 12)))   // nothing due
        #expect(try written() == thinned)

        #expect(history.thin(now: at(8, 12)))   // past a week: the day's newest
        #expect(kept() == [saves[23]])

        let daily = try written()
        #expect(!history.thin(now: at(29, 12)))   // nothing due, the oldest line 29 days old
        #expect(try written() == daily)

        #expect(!history.thin(now: at(30, 9)))   // the first save is 30 days old: no longer had
        #expect(!history.has(Digest.sha256(saves[0])) && history.has(Digest.sha256(saves[1])))
        #expect(kept() == [saves[23]])

        #expect(history.thin(now: at(30, 11)))   // the last one too
        #expect(history.entries().isEmpty && !saves.contains { history.has(Digest.sha256($0)) })
    }

    @Test func aMonthOfSavesThinnedQuickly() throws {
        // Every save is a line of `thinned` for 30 days: 30,000 here, a light month. Thinning parsed
        // each line's time, seconds with History locked and the journal's queue waiting (PRD §8,
        // 2026-10-02). Now a thin with nothing due reads a line, and one with something due the file.
        let history = History(root: scratchFolder(), path: "/tmp/scratch.md")
        let now = Date(timeIntervalSince1970: 2_000_000_000), formatter = ISO8601DateFormatter()
        func sha(_ n: Int) -> String { let hex = String(n, radix: 16); return String(repeating: "0", count: 64 - hex.count) + hex }
        var lines = ""
        for day in (0..<30).reversed() {   // a thousand saves a day, the oldest 29 days and an hour old
            let time = formatter.string(from: now.addingTimeInterval(-Double(day) * 86_400 - 3_600))
            for k in 0..<1_000 { lines += sha(day * 1_000 + k) + " " + time + "\n" }
        }
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        try lines.write(to: history.directory.appendingPathComponent("thinned.txt"), atomically: true, encoding: .utf8)
        // Two versions kept in one clock hour (`now` is 33 minutes into one), two hours ago.
        try history.record(Data("older".utf8), parent: nil, source: "saved", time: now.addingTimeInterval(-2 * 3_600 - 600))
        try history.record(Data("newer".utf8), parent: nil, source: "saved", time: now.addingTimeInterval(-2 * 3_600))

        var start = Date()
        #expect(!history.thin(now: now))   // nothing due
        let idle = Date().timeIntervalSince(start)
        start = Date()
        #expect(history.thin(now: now.addingTimeInterval(86_400)))   // a day on: "older" let go, a day of lines 30 days old
        let due = Date().timeIntervalSince(start)
        print("thinned 30,000 lines: \(Int(idle * 1000)) ms with nothing due, \(Int(due * 1000)) ms a day on")
        #expect(idle < 0.25 && due < 1, "\(idle) s, \(due) s (Debug)")
        #expect(history.has(Digest.sha256(Data("older".utf8))) && history.has(sha(28_999)) && !history.has(sha(29_000)))
    }

    @Test func movesToAPathWithNone() throws {
        // An untitled buffer saved or renamed (§8, 2026-10-03): its History goes on at the new
        // path. Left at the old one, nothing ever opened or thinned it again.
        let root = scratchFolder()
        let old = History(root: root, path: "/tmp/Untitled/1/Untitled"), new = History(root: root, path: "/tmp/notes.md")
        try old.record(Data("one\n".utf8), parent: nil, source: "opened")
        try old.record(Data("two\n".utf8), parent: nil, source: "closed")
        old.noteSeen(Digest.sha256(Data("between\n".utf8)))
        try old.move(to: new)
        #expect(new.entries().map(\.source) == ["opened", "closed"])
        #expect(new.data(Digest.sha256(Data("two\n".utf8))) == Data("two\n".utf8))
        #expect(new.has(Digest.sha256(Data("between\n".utf8))))
        #expect(!FileManager.default.fileExists(atPath: old.directory.path) && old.entries().isEmpty)
        try old.move(to: new)   // nothing there now: nothing changes
        #expect(new.entries().count == 2)
    }

    @Test func mergesIntoAPathWithHistory() throws {
        // Saved over a file this Mac has History for: both kept, in time order, nothing left behind.
        let root = scratchFolder()
        let old = History(root: root, path: "/tmp/Untitled/2/Untitled 2"), new = History(root: root, path: "/tmp/saved.md")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try new.record(Data("file, day 1\n".utf8), parent: nil, source: "opened", time: now.addingTimeInterval(-86_400))
        try old.record(Data("buffer\n".utf8), parent: nil, source: "opened", time: now.addingTimeInterval(-3_600))
        try new.record(Data("both\n".utf8), parent: nil, source: "closed", time: now.addingTimeInterval(-1_800))
        try old.record(Data("both\n".utf8), parent: nil, source: "saved", time: now.addingTimeInterval(-60))
        old.noteSeen(Digest.sha256(Data("old's\n".utf8)), time: now.addingTimeInterval(-120))
        new.noteSeen(Digest.sha256(Data("new's\n".utf8)), time: now.addingTimeInterval(-240))
        try old.move(to: new)
        #expect(new.entries().map(\.source) == ["opened", "opened", "closed", "saved"])
        #expect(new.entries().map(\.time) == new.entries().map(\.time).sorted())
        for text in ["file, day 1\n", "buffer\n", "both\n"] {
            #expect(new.data(Digest.sha256(Data(text.utf8))) == Data(text.utf8))
        }
        #expect(new.has(Digest.sha256(Data("old's\n".utf8))) && new.has(Digest.sha256(Data("new's\n".utf8))))
        let seen = try String(contentsOf: new.directory.appendingPathComponent("thinned.txt"), encoding: .utf8).split(separator: "\n")
        #expect(seen.map { String($0.prefix(64)) } == [Digest.sha256(Data("new's\n".utf8)), Digest.sha256(Data("old's\n".utf8))])   // oldest first
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        new.thin(now: now)   // thinned as its own from now on: a day's versions all stay
        #expect(new.entries().count == 4)
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
