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
