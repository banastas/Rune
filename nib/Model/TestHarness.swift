// Debug-only scenarios for M1's single-Mac checks (PRD §8 "done when"), driven by
// launch arguments as Blit's UITestHarness is:
//
//   nib -NibScenario type|clipboard|crash|recover|external -NibScenarioLog /path [-NibMarker text]
//
// Each runs against the scratch test file (iCloud Drive/nib-spike/), writes PASS or
// FAIL lines to the log, and quits (crash ends with SIGKILL instead).

#if DEBUG
import AppKit
import NibSync
import NibText

@MainActor
enum TestHarness {
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
            case "two-mac": await twoMac(document, log, marker)
            default: log.line("FAIL unknown scenario")
            }
            log.line("done")
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
        log.check(fileAt != nil && ms(lastKey, fileAt!) <= 1500, "saved within 1.5 s of the last keystroke")
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
        let conflicted = await waitFor(8) { document.conflict != nil }
        log.check(conflicted, "dirty buffer: a conflict, not an overwrite (state \(document.state.line))")
        let disk = fileText(document)
        log.check(disk.contains("external two \(marker)") && !disk.contains("local edit \(marker)"), "the file still holds the other app's version")
        document.resolve(.both)
        let saved = await waitFor(15) { fileText(document).contains("local edit \(marker)") && fileText(document).contains("external two \(marker)") }
        log.check(saved, "Keep Both: both versions in the file")
        log.check(ConflictText.hasMarkers(fileText(document)), "between conflict markers")
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
        let conflicted = await waitFor(8) { document.conflict != nil }
        log.check(conflicted, "another version arrived: a conflict, not a replacement (state \(document.state.line))")
        log.check(document.editor.textView.string.contains("unsent \(marker)"), "this Mac's line is still in the buffer")
        document.resolve(.both)
        let both = await waitFor(10) { fileText(document).contains("unsent \(marker)") && fileText(document).contains("other version \(marker)") }
        log.check(both, "Keep Both: both lines in the file")
    }

    /// A note from a pretend other Mac names a version this Mac doesn't have: nib hands the
    /// file back, evicts it, downloads it and holds it again, keeping its text (SY14, S1b).
    static func refreshFromNote(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        await waitSynced(document, 20)
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

        // Both type at the same moment: one upload is refused, that Mac merges.
        await until(60)
        end()
        view.insertText("\n- clash from \(role) \(marker)\n", replacementRange: view.selectedRange())
        let deadline = Date().addingTimeInterval(50)   // room for an upload that times out (15 s) and its retry
        while Date() < deadline {
            if document.conflict != nil {
                log.line("\(role): conflict sheet · Keep Both")
                document.resolve(.both)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await until(115)
        document.becameActive()   // as if you looked at this Mac again
        await until(125)
        let text = view.string
        log.check(text.contains("- clash from a \(marker)") && text.contains("- clash from b \(marker)"), "\(role): both clash lines are here")
        let expected = TextFile.encode(text, as: document.format)
        log.check((try? Data(contentsOf: document.url)) == expected, "\(role): the file holds exactly the buffer")
        log.check(isSynced(document), "\(role): synced (state \(document.state.line))")
        log.line("\(role): file SHA-256 \(Digest.sha256(expected)) · compare with the other Mac's")
        await until(135)
    }

    /// Puts sample text on screen and holds still for a screenshot; also renders the
    /// window into a PNG from inside the app, next to the log.
    static func snapshot(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        let view = document.editor.textView
        let sample = "## Deploy\n```bash\nssh me@seedbox 'df -h ~/files'\n```\n\n## Email · Q4 vendor\nHi Sam, thanks for the quick turnaround on the invoice. We can ship on Friday if QA signs off.\n"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(sample, replacementRange: view.selectedRange())
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end - 20, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        await waitSynced(document, 20)
        guard let window = view.window else { log.line("FAIL no window"); return }
        window.setFrame(NSRect(x: 80, y: 120, width: 760, height: 420), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        view.scrollRangeToVisible(view.selectedRange())
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
        view.undoManager?.undo()
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
