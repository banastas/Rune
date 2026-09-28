// Debug-only scenarios for M1's single-Mac checks (PRD §8 "done when"), driven by
// launch arguments as Blit's UITestHarness is:
//
//   nib -NibScenario type|clipboard|crash|recover|external -NibScenarioLog /path [-NibMarker text]
//
// Each runs against the scratch test file (iCloud Drive/Nib/Test/, or nib-spike/ ad hoc), writes PASS or
// FAIL lines to the log, and quits (crash ends with SIGKILL instead).

#if DEBUG
import AppKit
import NibSync
import NibText

@MainActor
enum TestHarness {
    /// iCloud conflict versions a scenario pretends are there (a real one needs iCloud itself to
    /// reconcile two offline edits); `Document` reads them with the real ones, and marking them
    /// resolved takes them away.
    static var fakeConflictVersions: [CloudControl.ConflictVersion] = []

    static func runIfRequested(_ document: Document) {
        let defaults = UserDefaults.standard
        guard let scenario = defaults.string(forKey: "NibScenario") else { return }
        let log = HarnessLog(path: defaults.string(forKey: "NibScenarioLog") ?? "/tmp/nib-scenario.log")
        let marker = defaults.string(forKey: "NibMarker") ?? "marker-\(Int(Date().timeIntervalSince1970))"
        Task {
            log.line("scenario \(scenario) · \(document.url.lastPathComponent) · held \(document.held) · marker \(marker)")
            switch scenario {
            case "type": await typeAndSync(document, log, marker)
            case "clipboard": await clipboard(document, log)
            case "crash": await crash(document, log, marker)
            case "recover": await recover(document, log, marker)
            case "external": await external(document, log, marker)
            case "snapshot": await snapshot(document, log)
            case "undo": await undoRedo(document, log, marker)
            case "refresh": await refreshFromNote(document, log)
            case "unsent": await unsentThenIncoming(document, log, marker)
            case "merge": await mergeFromNote(document, log, marker)
            case "mergeview": await mergeView(document, log, marker)
            case "duplicates": await duplicates(document, log, marker)
            case "conflictversions": await conflictVersions(document, log, marker)
            case "history": await historyScenario(document, log, marker)
            case "two-mac": await twoMac(document, log, marker)
            default: log.line("FAIL unknown scenario")
            }
            log.line("done")
            // terminate(_:) does nothing while a sheet is attached, even one on its way out:
            // "unsent" resolves its conflict moments before this.
            _ = await waitFor(5) { NSApp.windows.allSatisfy { $0.attachedSheet == nil } }
            // From the run loop, as a menu's Quit arrives. Called from inside this task (a
            // main-queue job), quit's own save-and-resume work would queue behind it and wait.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    // MARK: Scenarios

    /// Typing reaches the journal, then the file, then iCloud, with the times.
    static func typeAndSync(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let started = Date()
        await type("\n- harness \(marker)\n", into: document)
        let lastKey = Date()
        log.line("typed \(ms(started, lastKey)) ms for \(marker.count + 12) characters")
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        var journalAt: Date?, fileAt: Date?, syncedAt: Date?
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, syncedAt == nil {
            if journalAt == nil, journal.read(path: document.url.path)?.text.contains(marker) == true { journalAt = Date() }
            if fileAt == nil, fileText(document).contains(marker) { fileAt = Date() }
            if fileAt != nil, case .synced = document.state { syncedAt = Date() }
            try? await Task.sleep(for: .milliseconds(20))
        }
        log.line("after the last keystroke: journal \(journalAt.map { "\(ms(lastKey, $0)) ms" } ?? "never seen (cleared by the save first?)") · file \(fileAt.map { "\(ms(lastKey, $0)) ms" } ?? "never") · synced \(syncedAt.map { "\(ms(lastKey, $0)) ms" } ?? "never")")
        let onDisk = (try? Data(contentsOf: document.url)) ?? Data()
        let expected = TextFile.encode(document.editor.textView.string, as: document.format)
        log.check(onDisk == expected, "the file holds exactly the buffer (\(onDisk.count) bytes)")
        // 1 s after typing pauses, plus up to about 1 s when the save waits for an upload of the
        // previous version that's still reading the file (M1: 2.2 s once). The journal is the promise.
        log.check(fileAt != nil && ms(lastKey, fileAt!) <= 2500, "saved within 2.5 s of the last keystroke")
        log.check(syncedAt != nil, "iCloud reported this version (state \(document.state.line))")
    }

    /// ⌘V inserts plain text only; ⌘C writes plain text only (PT1, PT2). The clipboard is put back.
    static func clipboard(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }
        let rich = NSAttributedString(string: "Rich\r\ntext", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.red])
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        log.line("clipboard types before paste: \(pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "")")
        let view = document.editor.textView
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        let before = (view.string as NSString).length
        view.paste(nil)
        let inserted = (view.string as NSString).substring(from: before)
        log.check(inserted == "Rich\ntext", "paste inserted plain text with LF: \(inserted.debugDescription)")
        let attributes = view.textStorage?.attributes(at: before, effectiveRange: nil) ?? [:]
        let font = attributes[.font] as? NSFont
        log.check(font?.isFixedPitch == true && (attributes[.foregroundColor] as? NSColor) != .red, "no bold, no red: \(font?.fontName ?? "?")")
        view.setSelectedRange(NSRange(location: before, length: (inserted as NSString).length))
        view.copy(nil)
        let types = pasteboard.types?.map(\.rawValue) ?? []
        // NSStringPboardType is the legacy name macOS adds for the same plain-text type.
        let plain: Set<String> = [NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType"]
        log.check(!types.isEmpty && types.allSatisfy(plain.contains), "copy wrote plain text only: \(types.joined(separator: ", "))")
        view.undoManager?.undo()
        await document.flush(reason: "harness")
    }

    /// Types with saving held off, waits for the journal, then dies without warning.
    static func crash(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await type("\n- crash \(marker)\n", into: document)
        try? await Task.sleep(for: .milliseconds(600))
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        log.check(journal.read(path: document.url.path)?.text.contains(marker) == true, "the journal has the typing 600 ms later")
        log.check(!fileText(document).contains(marker), "the file doesn't (saving was held off for this test)")
        log.line("SIGKILL")
        kill(getpid(), SIGKILL)
    }

    /// The launch after `crash`: the typing is back and gets saved and synced.
    static func recover(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        log.check(document.editor.textView.string.contains(marker), "the buffer has the typing from before the crash")
        log.check(document.notice?.contains("RECOVERED") == true, "the strip says so: \(document.notice ?? "nothing")")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !fileText(document).contains(marker) { try? await Task.sleep(for: .milliseconds(50)) }
        log.check(fileText(document).contains(marker), "and it's in the file")
        await waitSynced(document, 20)
        log.check(isSynced(document), "and in iCloud (state \(document.state.line))")
    }

    /// Another app writes the file (SY5, SY6): no edits → reload; edits → conflict, nothing overwritten, Keep Both.
    static func external(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        append("external one \(marker)", to: document.url)
        let reloaded = await waitFor(8) { document.editor.textView.string.contains("external one \(marker)") }
        log.check(reloaded, "clean buffer: reloaded the other app's version (\(document.notice ?? "no notice"))")
        await waitSynced(document, 20)

        await type("\n- local edit \(marker)\n", into: document)   // dirty; saving held off by NibSaveIdle
        append("external two \(marker)", to: document.url)
        let blocked = await waitFor(8) { !ours(document, marker).isEmpty }
        log.check(blocked && document.editor.textView.string.contains("local edit \(marker)"),
                  "dirty buffer: both versions in the text, between markers, not an overwrite (\(ours(document, marker).count) block)")
        let saved = await waitFor(15) {
            let disk = fileText(document)
            return disk.contains("local edit \(marker)") && disk.contains("external two \(marker)") && ConflictText.hasMarkers(disk)
        }
        log.check(saved, "and in the file, between conflict markers")
        let resolved = await keepBoth(document, marker)
        let disk = fileText(document)
        log.check(resolved && disk.contains("local edit \(marker)") && disk.contains("external two \(marker)"), "⌘3 keeps both: the markers gone, both lines in the file")
        await waitSynced(document, 20)
        log.check(isSynced(document), "and synced (state \(document.state.line))")
    }

    /// Undo and redo work, and an undo is saved like any edit (ED1).
    static func undoRedo(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView
        await type("\n- undo \(marker)\n", into: document)
        log.check(view.undoManager?.canUndo == true, "there is something to undo (\(view.undoManager?.undoActionName ?? "none"))")
        view.undoManager?.undo()
        log.check(!view.string.contains(marker), "undo removed the typing")
        view.undoManager?.redo()
        log.check(view.string.contains(marker), "redo put it back")
        view.undoManager?.undo()
        await document.flush(reason: "harness")
        _ = await waitFor(10) { !fileText(document).contains(marker) }
        log.check(!fileText(document).contains(marker), "the undo was saved to the file")
        await waitSynced(document, 20)
        log.check(isSynced(document), "and synced (state \(document.state.line))")
    }

    /// Regression for the two-Mac test at 09:25: a version saved here but not yet uploaded
    /// is still this Mac's work. Another version arriving must bring the conflict sheet,
    /// not replace it. Run with -NibHoldUploads YES, so the save can't reach iCloud.
    static func unsentThenIncoming(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await type("\n- unsent \(marker)\n", into: document)
        let saved = await waitFor(8) { fileText(document).contains("unsent \(marker)") && !document.dirty }
        log.check(saved, "saved on this Mac, not uploaded (dirty \(document.dirty), unsent \(document.unsent))")
        append("other version \(marker)", to: document.url)
        let blocked = await waitFor(8) { !ours(document, marker).isEmpty }
        log.check(blocked, "another version arrived: both in the text between markers, not a replacement (\(ours(document, marker).count) block)")
        log.check(document.editor.textView.string.contains("unsent \(marker)"), "this Mac's line is still in the buffer")
        let both = await keepBoth(document, marker)
        log.check(both && fileText(document).contains("unsent \(marker)") && fileText(document).contains("other version \(marker)"),
                  "⌘3 keeps both: both lines in the file, no markers")
    }

    /// A version from a pretend other Mac, made (its note says) from the version this Mac
    /// last uploaded, arrives while this Mac has an unsent edit elsewhere in the file: a
    /// clean three-way merge, no sheet, one undo step (§4.7, §4.8 A).
    static func mergeFromNote(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView
        // The base: a version this Mac uploaded.
        await type("\n- merge base \(marker)\n", into: document)
        _ = await waitFor(10) { document.dirty }
        await waitSynced(document, 20)
        guard let base = document.debugSnapshot.uploadedSHA, isSynced(document) else {
            log.line("FAIL nothing uploaded to merge from (state \(document.state.line))"); return
        }
        let baseText = view.string
        // From here on nothing reaches iCloud (as with -NibHoldUploads), so this edit stays unsent.
        UserDefaults.standard.register(defaults: ["NibHoldUploads": true])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("- merge mine \(marker)\n", replacementRange: view.selectedRange())
        await endOfEvent(view)
        let saved = await waitFor(8) { fileText(document).contains("merge mine \(marker)") && !document.dirty }
        log.check(saved && document.unsent, "this Mac's line is saved, not uploaded")
        // The other Mac's version, the base plus a line at the end; its note comes first, as from iCloud.
        let theirs = TextFile.encode(baseText + "- merge theirs \(marker)\n", as: document.format)
        try? Announcement(sha256: Digest.sha256(theirs), parent: base, device: "Test Mac", size: theirs.count).write(for: document.url)
        try? await Task.sleep(for: .seconds(3))
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        try? theirs.write(to: document.url)   // in place, as a fetch puts it there
        var sheet = false
        let arrived = await waitFor(10) {
            if !ours(document, marker).isEmpty { sheet = true }
            return view.string.contains("merge theirs \(marker)")
        }
        func count(_ line: String) -> Int { view.string.components(separatedBy: line).count - 1 }
        let lines = (mine: count("- merge mine \(marker)"), theirs: count("- merge theirs \(marker)"))
        log.check(arrived && !sheet && ours(document, marker).isEmpty && lines == (1, 1),
                  "merged with no conflict block: both lines, once each (mine \(lines.mine)×, theirs \(lines.theirs)×)")
        log.check(document.notice?.contains("MERGED 1 CHANGE FROM TEST MAC") == true, "the strip says so: \(document.notice ?? "nothing")")
        let merge = events.read().dropFirst(before).last { $0.event == "merge" }
        log.check(merge != nil, "the Sync Log has it: \(merge?.detail ?? "no merge event")")
        let synced = await waitFor(10) { fileText(document) == view.string }
        log.check(synced, "and it's saved: the file holds the buffer")
        let action = view.undoManager?.canUndo == true ? view.undoManager?.undoActionName ?? "" : "nothing to undo"
        view.undoManager?.undo()
        log.check(count("- merge mine \(marker)") == 1 && count("- merge theirs \(marker)") == 0,
                  "⌘Z undoes the merge in one step (\(action); then mine \(count("- merge mine \(marker)"))×, theirs \(count("- merge theirs \(marker)"))×)")
        view.undoManager?.redo()
        log.check(count("- merge theirs \(marker)") == 1 && count("- merge mine \(marker)") == 1, "and redo brings it back")
        _ = await waitFor(10) { fileText(document) == view.string }
        try? FileManager.default.removeItem(at: Announcement.url(for: document.url))
    }

    /// Four blocks in the text: Resolve… opens the merge view (§5.5). Three are resolved in its
    /// result (first version, second, both), Done puts it in the buffer and the file with one
    /// block left, and Cancel leaves the text as it was.
    static func mergeView(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView
        let header = "## merge view \(marker)\n"
        var sample = header
        for n in 1...4 {
            sample += "line \(n)\n<<<<<<< \(document.device) · 10:4\(n)\nmine \(n) \(marker)\n=======\ntheirs \(n) \(marker)\n>>>>>>> Test Mac · 10:3\(n)\n"
        }
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(sample, replacementRange: view.selectedRange())
        await endOfEvent(view)
        log.check(ours(document, marker).count == 4, "four blocks in the text")
        document.resolveConflicts()
        let opened = await waitFor(5) { document.merge != nil && view.window?.attachedSheet != nil }
        guard opened, let session = document.merge else { log.line("FAIL Resolve… didn't open the merge view"); return }
        log.check(true, "Resolve… with four blocks opened the merge view")
        log.check(session.first.text.contains("mine 4 \(marker)") && !session.first.text.contains("theirs 1 \(marker)")
                  && session.second.text.contains("theirs 1 \(marker)") && !session.second.text.contains("mine 4 \(marker)"),
                  "each pane holds one version's whole text (\(session.first.label) · \(session.second.label))")
        log.check(session.marks.first.contains(.changed) && session.marks.second.contains(.changed), "and marks what differs (~)")
        for choice in [ConflictBlock.Choice.first, .second, .both] {
            session.resolve(choice)   // each moves the caret on to the next block
            await endOfEvent(session.editor.textView)
        }
        let left = session.blocks.filter { (session.result as NSString).substring(with: $0.range).contains(marker) }.count
        log.check(left == 1, "three resolved in the result, each moving on to the next; \(left) left")
        try? await Task.sleep(for: .milliseconds(500))
        if let sheet = view.window?.attachedSheet, let content = sheet.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            let url = URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-mergeview.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        document.closeMerge(done: true)
        let applied = await waitFor(10) {
            let disk = fileText(document)
            return disk.contains("mine 1 \(marker)") && !disk.contains("theirs 1 \(marker)")
                && disk.contains("theirs 2 \(marker)") && !disk.contains("mine 2 \(marker)")
                && disk.contains("mine 3 \(marker)") && disk.contains("theirs 3 \(marker)") && ours(document, marker).count == 1
        }
        log.check(applied && view.window?.attachedSheet == nil, "Done: the result is in the buffer and the file, one block left")
        let before = view.string
        document.openMerge()
        _ = await waitFor(5) { document.merge != nil }
        document.merge?.resolve(.both)
        document.closeMerge(done: false)
        _ = await waitFor(3) { view.window?.attachedSheet == nil }
        log.check(view.string == before && ours(document, marker).count == 1, "Cancel: nothing changed, the block is still in the text")
        // Out again, from its heading to the end.
        let at = (view.string as NSString).range(of: header).location
        if at != NSNotFound { view.insertText("", replacementRange: NSRange(location: at, length: (view.string as NSString).length - at)) }
        _ = await waitFor(10) { !fileText(document).contains(marker) }
    }

    /// Duplicates beside the file (§4.8 C): an identical one goes to the Trash with a notice; one
    /// with new text is merged between markers and goes to the Trash once saved; one that's an
    /// earlier version, in History, goes to the Trash with nothing merged.
    static func duplicates(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView
        let folder = document.url.deletingLastPathComponent()
        let stem = document.url.deletingPathExtension().lastPathComponent, ext = document.url.pathExtension
        func free() -> URL {
            var n = 2
            while FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(stem) \(n).\(ext)").path) { n += 1 }
            return folder.appendingPathComponent("\(stem) \(n).\(ext)")
        }
        // Whatever is beside the file now counts as someone's own: the first look records it.
        UserDefaults.standard.removeObject(forKey: "siblings:" + document.url.path)
        await document.checkOthers(reason: "harness")

        let identical = free()
        try? TextFile.encode(view.string, as: document.format).write(to: identical)
        await document.checkOthers(reason: "harness")
        let gone = await waitFor(10) { !FileManager.default.fileExists(atPath: identical.path) && document.notice?.contains("(IDENTICAL) · IN THE TRASH") == true }
        log.check(gone, "an identical duplicate: to the Trash (\(document.notice ?? "no notice"))")

        let different = free()
        try? TextFile.encode(view.string + "- duplicate only \(marker)\n", as: document.format).write(to: different)
        await document.checkOthers(reason: "harness")
        let blocked = await waitFor(8) { !ours(document, marker).isEmpty }
        let labels = ours(document, marker).first.map { [$0.firstLabel, $0.secondLabel] } ?? []
        log.check(blocked && labels.contains { $0.hasPrefix(different.lastPathComponent) }, "one with new text: its text between markers (\(labels.joined(separator: " / ")))")
        let merged = await waitFor(15) {
            !FileManager.default.fileExists(atPath: different.path) && fileText(document).contains("duplicate only \(marker)")
                && document.notice?.contains("IT'S IN THE TRASH") == true
        }
        log.check(merged, "and to the Trash once the file had its text (\(document.notice ?? "no notice"))")
        let kept = await keepBoth(document, marker)
        log.check(kept && fileText(document).contains("duplicate only \(marker)"), "⌘3 keeps both: the line stays, the markers go")

        // The version as opened is in History, and the file has moved on from it.
        let now = Digest.sha256(TextFile.encode(view.string, as: document.format))
        let earlier = document.history.entries().last { ($0.source == "opened" || $0.source == "saved") && $0.sha256 != now }
        if let earlier, let data = document.history.data(earlier.sha256) {
            let old = free()
            try? data.write(to: old)
            let before = view.string
            await document.checkOthers(reason: "harness")
                let trashed = await waitFor(10) { !FileManager.default.fileExists(atPath: old.path) && document.notice?.contains("AN EARLIER VERSION, IN HISTORY") == true }
            log.check(trashed && view.string == before,
                      "an earlier version of the file: to the Trash, nothing merged (\(document.notice ?? "no notice"))")
        } else {
            log.line("FAIL no earlier version in History to try")
        }
        let sources = Set(document.history.entries().map(\.source))
        log.check(sources.contains("saved") && sources.contains { $0.hasPrefix("duplicate ") }, "History has what was saved and the duplicates")
    }

    /// iCloud conflict versions (§4.8 D), pretended: an identical one is marked resolved and
    /// nothing changes; one with new text goes between markers, labelled with the Mac that
    /// saved it, and is marked resolved once the file has its text.
    static func conflictVersions(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView
        let before = view.string
        fakeConflictVersions = [.init(data: TextFile.encode(before, as: document.format), savedBy: "Test Mac", modified: Date())]
        await document.checkOthers(reason: "harness")
        log.check(fakeConflictVersions.isEmpty && view.string == before, "an identical conflict version: marked resolved, nothing changed")

        fakeConflictVersions = [.init(data: TextFile.encode(before + "- conflict version only \(marker)\n", as: document.format), savedBy: "Test Mac", modified: Date())]
        await document.checkOthers(reason: "harness")
        let blocked = await waitFor(8) { !ours(document, marker).isEmpty }
        let labels = ours(document, marker).first.map { [$0.firstLabel, $0.secondLabel] } ?? []
        log.check(blocked && labels.contains { $0.hasPrefix("Test Mac") }, "one with new text: between markers (\(labels.joined(separator: " / ")))")
        let resolved = await waitFor(15) { fakeConflictVersions.isEmpty && fileText(document).contains("conflict version only \(marker)") }
        log.check(resolved, "and marked resolved once the file had its text")
        let kept = await keepBoth(document, marker)
        log.check(kept, "⌘3 keeps both: the markers go")
    }

    /// History (SY13): each saved version is kept; Revert To puts one back as an edit, and the
    /// version it replaced can be put back in turn.
    static func historyScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        await type("\n- history one \(marker)\n", into: document)
        _ = await waitFor(10) { fileText(document).contains("history one \(marker)") && !document.dirty }
        await type("- history two \(marker)\n", into: document)
        _ = await waitFor(10) { fileText(document).contains("history two \(marker)") && !document.dirty }
        _ = await waitFor(5) { document.history.entries().contains { text(document, $0).contains("history two \(marker)") } }
        let entries = document.history.entries()
        let one = entries.last { text(document, $0).contains("history one \(marker)") && !text(document, $0).contains("history two \(marker)") }
        let two = entries.last { text(document, $0).contains("history two \(marker)") }
        log.check(one != nil && two != nil, "both saved versions are in History (\(entries.count) versions)")
        guard let one, let two else { return }
        document.restore(one)
        let back = await waitFor(10) { fileText(document).contains("history one \(marker)") && !fileText(document).contains("history two \(marker)") }
        log.check(back && document.notice?.contains("BACK TO THE VERSION FROM") == true, "Revert To: the earlier version, in the buffer and the file (\(document.notice ?? "no notice"))")
        document.restore(two)
        let again = await waitFor(10) { fileText(document).contains("history two \(marker)") }
        log.check(again, "and the version it replaced came back from History")
        log.check(document.history.entries().contains { $0.source == "opened" }, "the version as opened is in History")
    }

    static func text(_ document: Document, _ entry: HistoryEntry) -> String {
        document.history.data(entry.sha256).map { TextFile.decode($0).text } ?? ""
    }

    /// A note from a pretend other Mac names a version this Mac doesn't have: nib hands the
    /// file back, evicts it, downloads it and holds it again, keeping its text (SY14, S1b).
    static func refreshFromNote(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        await waitSynced(document, 20)
        // As in the two-Mac test at 11:15: typed and uploaded shortly before the note arrives.
        await type("\n- before the note \(Int(Date().timeIntervalSince1970))\n", into: document)
        _ = await waitFor(10) { document.dirty }
        await waitSynced(document, 20)
        try? await Task.sleep(for: .seconds(3))
        let before = document.editor.textView.string
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let count = events.read().count
        try? Announcement(sha256: String(repeating: "0", count: 64), parent: nil, device: "Test Mac", size: 1).write(for: document.url)
        let ran = await waitFor(20) { events.read().dropFirst(count).contains { $0.event == "refresh" } }
        let last = events.read().dropFirst(count).filter { $0.event == "refresh" }.last
        log.check(ran && last?.detail?.hasPrefix("failed") == false, "the note led to a refresh: \(last?.detail ?? "none") (\(last?.ms ?? -1) ms)")
        _ = await waitFor(10) { document.held }
        log.check(document.held && CloudControl.status(document.url).paused == true, "the file is held again")
        log.check(document.editor.textView.string == before, "the text is unchanged (the server had this version)")
        log.check(fileText(document) == before, "and so is the file")
        try? FileManager.default.removeItem(at: Announcement.url(for: document.url))
    }

    /// Two Macs, the same test file, started with the same -NibAt (epoch seconds):
    ///   -NibRole a: at +5 s adds a line with its time; at +60 s adds a clash line.
    ///   -NibRole b: stays idle and must show a's line without anyone typing, first by
    ///   itself, then (from +25 s) as if the user switched to it; at +60 s adds its clash line.
    /// Both: a conflict is answered Keep Both; both come forward at +115 s; at +125 s both
    /// Macs must hold both clash lines, the file equal to the buffer, synced, the same bytes.
    static func twoMac(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        let defaults = UserDefaults.standard
        let role = defaults.string(forKey: "NibRole") ?? "a"
        let t0 = defaults.double(forKey: "NibAt")
        func until(_ offset: Double) async {
            let wait = t0 + offset - Date().timeIntervalSince1970
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        await waitReady(document)
        log.line("role \(role) · held \(document.held) · \(Int(t0 - Date().timeIntervalSince1970)) s to go")
        let view = document.editor.textView
        let lead = "- lead \(marker) written "
        func end() { view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0)) }

        if role == "a" {
            await until(5)
            end()
            view.insertText("\n\(lead)\(Int(Date().timeIntervalSince1970 * 1000))\n", replacementRange: view.selectedRange())
            await waitSynced(document, 20)
            log.check(isSynced(document), "a: the lead line is uploaded (state \(document.state.line))")
        } else {
            await until(0)   // the lead line comes at +5 s; wait for it from the start, not from opening
            func latency() -> Int {
                guard let range = view.string.range(of: lead) else { return -1 }
                let digits = view.string[range.upperBound...].prefix { $0.isNumber }
                return Int(Date().timeIntervalSince1970 * 1000) - (Int(digits) ?? 0)
            }
            // Informational: an idle Mac depends on iCloud pushing to it.
            if await waitFor(20, { view.string.contains(lead) }) {
                log.line("b: a's line arrived by itself, \(latency()) ms after a added it")
            } else {
                log.line("b: a's line didn't arrive by itself within 20 s")
            }
            // The promise: coming forward shows the newest version (the user switching Macs).
            await until(25)
            let cameForward = Date()
            document.becameActive()
            let seen = await waitFor(15) { view.string.contains(lead) }
            log.check(seen, "b: after coming forward, a's line is here \(seen ? "within \(Int(Date().timeIntervalSince(cameForward) * 1000)) ms" : "— never") (\(latency()) ms after a added it), with nothing typed here")
        }

        // Both type at the same moment in the same place: one upload is refused, and that
        // Mac merges; the two lines overlap, so the sheet comes up (Keep Both).
        await until(60)
        end()
        view.insertText("\n- clash from \(role) \(marker)\n", replacementRange: view.selectedRange())
        await answerBlocks(document, log, role, "clash", marker, until: t0 + 110)
        await until(115)
        document.becameActive()   // as if you looked at this Mac again
        await until(125)
        // Once each: at 13:22 a version merged twice, then a save merged with itself, and
        // both lines were there three and two times over, nested.
        func count(_ line: String) -> Int { view.string.components(separatedBy: line).count - 1 }
        let clashes = (a: count("- clash from a \(marker)"), b: count("- clash from b \(marker)"))
        log.check(clashes == (1, 1), "\(role): both clash lines are here, once each (a \(clashes.a)×, b \(clashes.b)×)")
        log.check(ours(document, marker).isEmpty && noBlocksInFile(document, marker), "\(role): the block was resolved (Keep Both), here too")

        // Then both type at the same moment in different places, a first in the file, b last:
        // the Mac whose upload is refused merges without asking (§4.7, §4.8 A).
        await until(130)
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        if role == "a" {
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.insertText("- apart from a \(marker)\n", replacementRange: view.selectedRange())
        } else {
            end()
            view.insertText("\n- apart from b \(marker)\n", replacementRange: view.selectedRange())
        }
        let sheets = await answerBlocks(document, log, role, "apart", marker, until: t0 + 180)
        await until(185)
        document.becameActive()
        await until(195)
        let merges = events.read().dropFirst(before).filter { $0.event == "merge" }
        for merge in merges { log.line("\(role): merged by itself · \(merge.detail ?? "")") }
        let apart = (a: count("- apart from a \(marker)"), b: count("- apart from b \(marker)"))
        log.check(apart == (1, 1) && sheets == 0, "\(role): both apart lines are here, once each, with no conflict block (a \(apart.a)×, b \(apart.b)×, blocks written \(sheets))")
        log.check(view.string.hasPrefix("- apart from a \(marker)\n"), "\(role): a's line is first in the file, b's last")
        let expected = TextFile.encode(view.string, as: document.format)
        log.check((try? Data(contentsOf: document.url)) == expected, "\(role): the file holds exactly the buffer")
        log.check(isSynced(document), "\(role): synced (state \(document.state.line))")
        log.line("\(role): file SHA-256 \(Digest.sha256(expected)) · compare with the other Mac's")
        await until(205)
    }

    /// Blocks this Mac wrote (a "conflict" in its Sync Log) are resolved with Keep Both once
    /// they've been in the text 5 s, as a person would take a moment; blocks that arrive from
    /// the other Mac are left for it, whose resolution arrives in turn. Returns how many
    /// times this Mac wrote blocks.
    @discardableResult
    static func answerBlocks(_ document: Document, _ log: HarnessLog, _ role: String, _ phase: String, _ marker: String, until deadline: Double) async -> Int {
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        var written = 0, since: Date?
        while Date().timeIntervalSince1970 < deadline {   // room for an upload that times out (15 s) and its retry
            let conflicts = events.read().dropFirst(before).filter { $0.event == "conflict" }.count
            if conflicts > written {
                written = conflicts
                since = Date()
                let n = ours(document, marker).count
                log.line("\(role): \(phase) conflict · \(n) block\(n == 1 ? "" : "s") in the text\(document.mergedAroundBlocks ? " (three-way)" : "")")
            }
            if let up = since, Date().timeIntervalSince(up) >= 5, !ours(document, marker).isEmpty {
                let resolved = await keepBoth(document, marker)
                log.line("\(role): \(phase) blocks · ⌘3 Keep Both\(resolved ? "" : " · FAILED")")
                since = nil
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return written
    }

    /// This run's blocks: the ones with its marker in them. (The test file may hold others.)
    static func ours(_ document: Document, _ marker: String) -> [ConflictBlock] {
        let text = document.editor.textView.string as NSString
        return document.blocks.filter { text.substring(with: $0.range).contains(marker) }
    }

    /// No block in the file with this run's marker in it.
    static func noBlocksInFile(_ document: Document, _ marker: String) -> Bool {
        let disk = fileText(document)
        return !ConflictText.blocks(in: disk).contains { (disk as NSString).substring(with: $0.range).contains(marker) }
    }

    /// ⌘3 in each of this run's blocks, as the Conflicts menu does: true once the file has none.
    static func keepBoth(_ document: Document, _ marker: String) async -> Bool {
        let view = document.editor.textView
        for _ in 0..<20 {
            guard let block = ours(document, marker).first else { break }
            view.setSelectedRange(NSRange(location: block.first.location, length: 0))
            guard await waitFor(2, { document.caretBlock != nil }) else { return false }
            document.resolveBlock(.both)
            await endOfEvent(view)
        }
        return await waitFor(15) { noBlocksInFile(document, marker) }
    }

    /// Puts sample text on screen and holds still for a screenshot; also renders the
    /// window into a PNG from inside the app, next to the log.
    static func snapshot(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        if UserDefaults.standard.bool(forKey: "NibSnapshotHistory") {   // the History window, as File › Revert To opens it
            let menu = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.item(withTitle: "Revert To")?.submenu
            if let browse = menu?.items.last, let index = menu?.index(of: browse) { menu?.performActionForItem(at: index) }
            _ = await waitFor(5) { NSApp.windows.contains { $0.title.hasPrefix("History") && $0.isVisible } }
            try? await Task.sleep(for: .milliseconds(800))
            if let window = NSApp.windows.first(where: { $0.title.hasPrefix("History") }), let content = window.contentView?.superview ?? window.contentView,
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-history.png"))
                log.line("rendered snapshot-history.png")
            } else {
                log.line("FAIL no History window")
            }
            return
        }
        let view = document.editor.textView
        var sample = "## Deploy\n```bash\nssh me@seedbox 'df -h ~/files'\n```\n\n## Email · Q4 vendor\nHi Sam, thanks for the quick turnaround on the invoice. We can ship on Friday if QA signs off.\n"
        if UserDefaults.standard.bool(forKey: "NibSnapshotConflict") {   // the banner and a block (§5.4)
            sample = "## Email · Q4 vendor\nHi Sam, thanks for the quick turnaround.\n<<<<<<< \(document.device) · 10:42\nWe can ship on Friday if QA signs off.\n=======\nWe can ship Thursday.\n>>>>>>> Bill’s MacBook Air · 10:41\nAlso: invoice attached.\n"
        }
        let sampleRange = NSRange(location: (view.string as NSString).length, length: (sample as NSString).length)
        view.setSelectedRange(NSRange(location: sampleRange.location, length: 0))
        view.insertText(sample, replacementRange: view.selectedRange())
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: document.blocks.last.map { $0.first.location + 4 } ?? end - 20, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        await waitSynced(document, 20)
        guard let window = view.window else { log.line("FAIL no window"); return }
        window.setFrame(NSRect(x: 80, y: 120, width: 760, height: 420), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.scrollRangeToVisible(document.blocks.last.map { NSRange(location: $0.range.location, length: $0.range.length + 30) } ?? view.selectedRange())
        view.needsDisplay = true
        try? await Task.sleep(for: .milliseconds(600))
        log.line("window \(window.windowNumber)")
        if let content = window.contentView?.superview ?? window.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            let url = URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-in-app.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log.line("rendered \(url.lastPathComponent)")
        }
        try? await Task.sleep(for: .seconds(5))   // time for an outside screenshot
        // Out again as an edit, by its own range: nothing else writes the file meanwhile.
        if NSMaxRange(sampleRange) <= (view.string as NSString).length,
           (view.string as NSString).substring(with: sampleRange) == sample {
            view.insertText("", replacementRange: sampleRange)
        } else {
            log.line("FAIL the sample moved; left in the test file")
        }
        await document.flush(reason: "harness")
    }

    // MARK: Helpers

    static func waitReady(_ document: Document) async {
        _ = await waitFor(30) { document.ready }
    }

    static func waitSynced(_ document: Document, _ seconds: Double) async {
        _ = await waitFor(seconds) { isSynced(document) }
    }

    static func isSynced(_ document: Document) -> Bool {
        if case .synced = document.state { return true }
        return false
    }

    static func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Keystrokes at the end of the buffer, 30 ms apart, as the editor receives them.
    static func type(_ text: String, into document: Document) async {
        let view = document.editor.textView
        for character in text {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText(String(character), replacementRange: view.selectedRange())
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    /// Typing here comes without key events, and AppKit closes an undo group at the end of
    /// an event: post one, as a keystroke would end, so what follows is its own undo step.
    static func endOfEvent(_ view: NSTextView) async {
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
        if let event { NSApp.postEvent(event, atStart: false) }
        _ = await waitFor(2) { (view.undoManager?.groupingLevel ?? 0) == 0 }
    }

    static func fileText(_ document: Document) -> String {
        (try? String(contentsOf: document.url, encoding: .utf8)) ?? ""
    }

    /// An uncoordinated write from another process, like `echo >> file`.
    static func append(_ line: String, to url: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf '%s\\n' \"$1\" >> \"$0\"", url.path, line]
        try? shell.run()
        shell.waitUntilExit()
    }

    static func ms(_ from: Date, _ to: Date) -> Int { Int((to.timeIntervalSince(from) * 1000).rounded()) }

    static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    static func restorePasteboard(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

/// PASS and FAIL lines, to a file and stdout.
final class HarnessLog: @unchecked Sendable {
    let path: String
    private(set) var failures = 0

    init(path: String) {
        self.path = path
        try? Data().write(to: URL(fileURLWithPath: path))
    }

    func line(_ text: String) {
        let stamp = SyncState.clock.string(from: Date())
        let entry = "\(stamp) \(text)\n"
        print(entry, terminator: "")
        fflush(stdout)
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
            try? handle.close()
        }
    }

    func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        line("\(ok ? "PASS" : "FAIL") \(what)")
    }
}
#endif
