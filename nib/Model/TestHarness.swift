// Debug-only scenarios for M1's single-Mac checks (PRD §8 "done when"), driven by
// launch arguments as Blit's UITestHarness is:
//
//   nib -NibScenario type|clipboard|crash|recover|external -NibScenarioLog /path [-NibMarker text]
//
// Each runs against the scratch test file (iCloud Drive/Nib/Test/, or nib-spike/ ad hoc), writes PASS or
// FAIL lines to the log, and quits (crash ends with SIGKILL instead).

#if DEBUG
import AppKit
import Carbon.HIToolbox
import NibSync
import NibSyntax
import NibText
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum TestHarness {
    /// iCloud conflict versions a scenario pretends are there (a real one needs iCloud itself to
    /// reconcile two offline edits); `Document` reads them with the real ones, and marking them
    /// resolved takes them away.
    static var fakeConflictVersions: [CloudControl.ConflictVersion] = []
    /// -NibFailPauses n -NibFailPausesFor <name prefix>: the first n holds of those files fail
    /// as they do when iCloud's helper doesn't answer (the `holdretry` scenario).
    static var failPauses = NibDefaults.store.integer(forKey: "NibFailPauses")
    static let failPausesFor = NibDefaults.store.string(forKey: "NibFailPausesFor")
    /// The `refusal` scenario: the next uploads refused as if another Mac had uploaded first,
    /// and the next fetches answered "nothing newer", as iCloud can for a held file.
    static var refuseUploads = 0
    static var staleFetches = 0
    /// The `full` scenario: uploads refused as when iCloud storage is full; writes failing as on a full disk.
    static var storageFull = false
    static var diskFull = false
    /// The `full` scenario's own Trash: a scenario's Nib offers and empties only this, never the Mac's.
    static var fakeTrash: URL?
    /// The `evicted` scenario: this Mac offline, as far as Nib's own files go (iCloud isn't asked).
    static var offline = false
    /// The `evicted` scenario: online, with iCloud slow to bring a file (a download's wait gives up
    /// after 2 s, and iCloud isn't asked).
    static var slowDownload = false
    /// The `large` scenario's answer to ED9's question about a file over 100 MB, and the files asked about.
    static var largeFileAnswer: Bool?
    static var largeFileAsked: [String] = []
    /// The `icloudoff` scenario: as if iCloud Drive were off on this Mac.
    static var iCloudOff = false
    /// The `history` scenario's span for History's saves, in place of 5 minutes; and its quit
    /// cut off by the 10 s watchdog after its save, as when iCloud is slow to take the file back
    /// (-NibSlowQuit; the suite at 00:19 on 2026-10-02 lost the version closed with that way).
    static var historySpan: TimeInterval?
    static let slowQuit = NibDefaults.store.bool(forKey: "NibSlowQuit")
    /// Hands the file back for real, taking the server's version, just before the next forced
    /// refresh: the hold lost as a hand-back a moment before can lose it (`refusal-lost-hold`).
    static var loseHoldBeforeRefresh = NibDefaults.store.bool(forKey: "NibLoseHold")
    /// The next fetch brings this, as if another Mac had uploaded it (the `merge` scenario's
    /// -NibNoteTiming variants: versions from iCloud are the ones that wait for their note).
    static var fakeNewer: Data?
    /// -NibFailResumes n: the next hand-backs fail as when iCloud's helper doesn't answer;
    /// -NibUnsupportedPauses n (with -NibFailPausesFor): the next holds answer "not supported".
    static var failResumes = NibDefaults.store.integer(forKey: "NibFailResumes")
    /// -NibStillUploading n: the next n waits for iCloud's upload find it still uploading when
    /// their 15 s are up, as the suite's `merge` did at 17:55 on 2026-10-02.
    static var stillUploading = NibDefaults.store.integer(forKey: "NibStillUploading")
    static var unsupportedPauses = NibDefaults.store.integer(forKey: "NibUnsupportedPauses")

    static func runIfRequested(_ document: Document) {
        let defaults = NibDefaults.store
        guard let scenario = defaults.string(forKey: "NibScenario") else { return }
        let log = HarnessLog(path: defaults.string(forKey: "NibScenarioLog") ?? "/tmp/nib-scenario.log")
        let marker = defaults.string(forKey: "NibMarker") ?? "marker-\(Int(Date().timeIntervalSince1970))"
        MainThreadWatch.start(log)
        Task {
            // §6.5's cold launch: from the process starting to the scratch window up with its text.
            _ = await waitFor(3) { AppDelegate.scratchWindow?.isVisible == true }
            // Editable: the window up and the text in it, whichever came later; the hold (waiting
            // for iCloud's upload, then pausing) comes after, the text editable meanwhile.
            let launch = processStart().map { started -> String in
                let moments = [AppDelegate.launchMoments.window, AppDelegate.launchMoments.text]
                let editable = moments.contains(where: { $0 == nil }) ? Date() : moments.compactMap { $0 }.max()!
                let marks = AppDelegate.launchMarks.map { " \($0.name) at \(Int($0.time.timeIntervalSince(started) * 1000))," }.joined()
                let phases = marks + AppDelegate.launchPhases.map { " (\($0.name) \(Int($0.seconds * 1000)) ms)" }.joined()
                func at(_ moment: Date?) -> String { moment.map { "\(Int($0.timeIntervalSince(started) * 1000))" } ?? "—" }
                return " · editable \(Int(editable.timeIntervalSince(started) * 1000)) ms after launch (window \(at(AppDelegate.launchMoments.window)), text \(at(AppDelegate.launchMoments.text))), held \(Int(Date().timeIntervalSince(started) * 1000)) ms" + (phases.isEmpty ? "" : ":" + phases)
            } ?? ""
            log.line("scenario \(scenario) · \(document.url.lastPathComponent) · held \(document.held) · marker \(marker) · the focus stays with \(ScenarioFocus.keeper)\(launch)")
            switch scenario {
            case "type": await typeAndSync(document, log, marker)
            case "clipboard": await clipboard(document, log)
            case "crash": await crash(document, log, marker)
            case "recover": await recover(document, log, marker)
            case "crash-blocks": await crashWithBlocks(document, log, marker)
            case "crash-big": await crashBig(log, marker)
            case "recover-big": await recoverBig(log, marker)
            case "recover-blocks": await recoverWithBlocks(document, log, marker)
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
            case "findhistory": await findHistoryScenario(document, log, marker)
            case "gitmarks": await gitMarksScenario(log, marker)
            case "files": await files(log, marker)
            case "copykey": await copyKeyScenario(log, marker)
            case "syntax": await syntaxScenario(log, marker)
            case "themes": await themes(log, marker)
            case "untitled": await untitledScenario(log, marker)
            case "synclog": await syncLogScenario(document, log, marker)
            case "holdretry": await holdRetryScenario(log, marker)
            case "bigfile": await bigFile(log, marker)
            case "refusal": await refusal(document, log, marker)
            case "cleantext": await cleanText(document, log, marker)
            case "lines": await lineCommands(log, marker)
            case "find": await findScenario(log, marker)
            case "palette": await paletteScenario(log, marker)
            case "gutter": await gutterScenario(log, marker)
            case "tidy": await tidyScenario(log, marker)
            case "menubar": await menuBarScenario(Documents.scratch, log, marker)
            case "firstrun": await firstRunScenario(Documents.scratch, log, marker)
            case "cli": await cliScenario(Documents.scratch, log, marker)
            case "fileops": await fileOpsScenario(Documents.scratch, log, marker)
            case "access": await accessScenario(log, marker)
            case "moved": await movedScenario(log, marker)
            case "deleted": await deletedScenario(log, marker)
            case "full": await fullScenario(Documents.scratch, log, marker)
            case "icloudoff": await iCloudOffScenario(log, marker)
            case "evicted": await evictedScenario(log, marker)
            case "large": await largeScenario(log, marker)
            case "writes": await writesScenario(log, marker)
            case "carets": await caretsScenario(log, marker)
            case "minimap": await minimapScenario(log, marker)
            case "mdlist": await markdownListScenario(log, marker)
            case "widescroll": await wideScrollScenario(log, marker)
            case "headings": await headingsScenario(log, marker)
            case "pairs": await pairsScenario(log, marker)
            case "receipts": await receiptsScenario(log, marker)
            case "defaultapps": await defaultAppsScenario(log, marker)
            case "synchud": await syncHUDScenario(Documents.scratch, log, marker)
            case "about": await aboutScenario(log, marker)
            case "dock": await dockScenario(log, marker)
            case "services": await servicesScenario(Documents.scratch, log, marker)
            case "license": await licenseScenario(Documents.scratch, log, marker)
            case "nap": await napScenario(document, log, marker)
            case "findjump": await findJumpScenario(log, marker)
            case "uploads": await uploadsScenario(document, log, marker)
            case "perf": await perfScenario(Documents.scratch, log, marker)
            case "launch": await waitReady(document)   // §6.5's cold launch: the first line says it
            case "bigopen": await bigOpen(log, marker)
            case "idlebig":   // §6.5's idle memory with a scratch-sized file open (2.4 MB of Markdown, untitled)
                await waitReady(document)
                // -NibIdleBigSize n: n bytes in place of 2.4 MB (the user's scratch file was 223 KB on
                // 2026-10-02: under 256K, so its syntax tree is the whole file's).
                let asked = NibDefaults.store.integer(forKey: "NibIdleBigSize"), wanted = asked > 0 ? asked : 2_400_000
                let size = wanted >= 1_000_000 ? String(format: "%.1f MB", Double(wanted) / 1_000_000) : "\(wanted / 1_000) KB"
                var md = "# Scratch-sized \(marker)\n", m = 0
                while md.utf8.count < wanted {
                    m += 1
                    md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
                }
                // -NibIdleBigExtension txt: the same text as plain text, no syntax tree.
                let ext = NibDefaults.store.string(forKey: "NibIdleBigExtension") ?? "md"
                if let url = Untitled.create(text: md, name: "idlebig-\(marker).\(ext)") {
                    AppDelegate.openFile(url)
                    _ = await waitFor(20) { Documents.existing(for: url)?.ready == true }
                    // At the top, then at the end, where a scratch file is written: getting there
                    // reads the whole text a chunk at a time for places to start, each tree let go.
                    try? await Task.sleep(for: .seconds(5))
                    log.line(String(format: "idle with %@ open, at the top: %.1f MB", size, footprint()))
                    if let view = Documents.existing(for: url)?.editor.textView {
                        let length = (view.string as NSString).length
                        view.setSelectedRange(NSRange(location: length, length: 0))
                        view.reveal(length)
                    }
                    // -NibIdleBigSlices n: idle for n 5-second slices (8), to watch for growth.
                    let sliceCount = NibDefaults.store.integer(forKey: "NibIdleBigSlices"), slices = sliceCount > 0 ? sliceCount : 8
                    for _ in 0..<slices {
                        let a = usage(), start = Date()
                        try? await Task.sleep(for: .seconds(5))
                        let b = usage(), seconds = Date().timeIntervalSince(start)
                        log.line(String(format: "idle with %@ open: %.1f MB, %.2f%% CPU, %.1f wakeups a second", size, footprint(),
                                        (b.cpu - a.cpu) / seconds * 100, Double(b.wakeups - a.wakeups) / seconds))
                    }
                    Untitled.letGo(url)
                    Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
                    _ = await waitFor(10) { Documents.existing(for: url) == nil }
                    // Its History too (the version opened, and closed with): nothing opens that path again.
                    try? FileManager.default.removeItem(at: History(root: NibPaths.support.appendingPathComponent("History"), path: url.path).directory)
                }
            case "idle":   // §6.5's idle CPU: synced, then nothing for a minute, for `sample` to watch
                await waitReady(document)
                await waitSynced(document, 30)
                log.line("idle from now, for 60 s")
                for _ in 0..<12 {   // CPU and wakeups in 5 s slices: launch's work tailing off, or steady?
                    let a = usage(), start = Date()
                    try? await Task.sleep(for: .seconds(5))
                    let b = usage(), seconds = Date().timeIntervalSince(start)
                    log.line(String(format: "idle: %.2f%% CPU, %.1f wakeups a second, %.1f MB", (b.cpu - a.cpu) / seconds * 100, Double(b.wakeups - a.wakeups) / seconds, footprint()))
                }
            case "handback": await handBack(document, log)
            case "handback-return": await handBackReturn(document, log)
            case "untitled-return": await untitledReturn(log, marker)
            case "untitled-quit": await untitledQuit(log, marker)
            case "reopen": await reopenScenario(log, marker)
            case "reopen-return": await reopenReturn(log, marker)
            case "history-closed": await historyClosed(document, log, marker)
            case "two-mac": await twoMac(document, log, marker)
            case "two-mac-remote": await twoMacRemote(log, marker)
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
        // The empty scratch file's line, for when it's empty (§5.1; the QA review's F56).
        log.check(document === Documents.scratch && document.editor.textView.placeholder == Document.emptyScratchLine,
                  "the scratch file says what it's for while it's empty: “\(document.editor.textView.placeholder ?? "nothing")”")
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

    /// Sublime's line commands (ED6, KB4) on a JavaScript file indented with two spaces: the
    /// indentation found, each command and its undo, // comments, auto-indent, Tab, Go to
    /// Line; then <!-- --> comments in the Markdown scratch file, and the Text menu.
    static func lineCommands(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("lines-\(marker).js")
        let original = "function add() {\n  const a = 1;\n  const b = 2;\n  return a + b;\n}\n"
        try? Data(original.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            NibDefaults.store.removeObject(forKey: Document.indentationKey + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        NibDefaults.store.removeObject(forKey: Document.indentationKey + url.path)
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView
        log.check(document.indentation == .spaces(2) && document.indentationLabel == "2 SPACES", "indentation found: \(document.indentationLabel)")
        func at(_ word: String, _ offset: Int = 0) {
            view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: word).location + offset, length: 0))
        }
        func run(_ command: () -> Void) async { command(); await endOfEvent(view) }
        func undo() async { view.undoManager?.undo(); await endOfEvent(view) }
        func lines() -> [String] { view.string.components(separatedBy: "\n") }

        at("const b", 3); await run { view.duplicateLine(nil) }
        log.check(lines()[2] == "  const b = 2;" && lines()[3] == "  const b = 2;" && view.undoManager?.undoActionName == "Duplicate Line",
                  "Duplicate Line (⇧⌘D): the line below itself")
        await undo()
        at("const b"); await run { view.moveLineUp(nil) }
        log.check(lines()[1] == "  const b = 2;" && lines()[2] == "  const a = 1;", "Move Line Up (⌃⌘↑)")
        await run { view.moveLineDown(nil) }
        log.check(view.string == original, "and Move Line Down (⌃⌘↓) puts it back")
        at("const a"); await run { view.selectWholeLine(nil) }
        let one = (view.string as NSString).substring(with: view.selectedRange())
        await run { view.selectWholeLine(nil) }
        let two = (view.string as NSString).substring(with: view.selectedRange())
        log.check(one == "  const a = 1;\n" && two == "  const a = 1;\n  const b = 2;\n", "Select Line (⌘L), and again: the next line too")
        at("{"); await run { view.joinLines(nil) }
        log.check(lines()[0] == "function add() { const a = 1;", "Join Lines (⌘J): \(lines()[0].debugDescription)")
        await undo()
        at("return"); await run { view.indentLines(nil) }
        log.check(lines()[3] == "    return a + b;", "Indent (⌘]) by the file's two spaces")
        await run { view.outdentLines(nil) }
        log.check(lines()[3] == "  return a + b;", "and Outdent (⌘[)")
        at("const a"); await run { view.toggleComment(nil) }
        log.check(lines()[1] == "  // const a = 1;", "Toggle Comment (⌘/) in JavaScript: \(lines()[1].debugDescription)")
        await run { view.toggleComment(nil) }
        log.check(view.string == original, "and again, uncommented")
        at("const a = 1;", 12); await run { view.insertNewline(nil) }
        let caret = view.selectedRange().location
        log.check(lines()[2] == "  " && (view.string as NSString).substring(to: caret).hasSuffix("1;\n  "), "Return keeps the indentation")
        await run { view.insertTab(nil) }
        log.check(lines()[2] == "    ", "and Tab adds the file's two spaces")
        let typing = view.undoManager?.undoActionName ?? ""
        await undo()
        log.check(view.string == original && typing == "Typing", "and one undo takes both back: they're typing (\(typing))")
        let went = document.goToLine("4:3")
        log.check(went && document.cursor == (4, 3), "Go to Line (⌃G) 4:3: \(document.cursor)")
        document.goingToLine = true
        try? await Task.sleep(for: .milliseconds(300))
        let field = view.window?.firstResponder is NSTextView && view.window?.firstResponder !== view
        log.check(field, "⌃G opens the field in the strip's line slot")
        document.goToLine("1")

        // Convert Indentation (the QA review's F50): the leading spaces made tabs at the file's
        // width, one undo step, the caret where it was in the text; the choice kept for the file.
        at("const a")
        document.convertIndentation(toTabs: true)
        await endOfEvent(view)
        let tabbed = original.replacingOccurrences(of: "\n  ", with: "\n\t")
        let caretKept = (view.string as NSString).substring(from: view.selectedRange().location).hasPrefix("const a")
        log.check(view.string == tabbed && caretKept && document.indentationLabel == "TABS"
                  && NibDefaults.store.string(forKey: Document.indentationKey + url.path) == "tabs:2"
                  && view.undoManager?.undoActionName == "Convert Indentation" && document.notice == "CONVERTED THE INDENTATION TO TABS ON 3 LINES · ⌘Z UNDOES",
                  "Convert Indentation to Tabs: \(view.string.components(separatedBy: "\n")[1].debugDescription), the caret kept (\(caretKept)), \(document.indentationLabel), “\(document.notice ?? "no notice")”")
        await undo()
        log.check(view.string == original, "and ⌘Z takes it back")
        // Line endings: CRLF from the next save, as an edit ⌘Z takes back.
        document.setLineEnding(.crlf)
        let edited = document.dirty && view.undoManager?.undoActionName == "Line Endings" && document.notice == "LINE ENDINGS CRLF · ⌘Z UNDOES"
        await document.flush(reason: "test")
        let crlf = (try? Data(contentsOf: url)) == Data(original.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        await undo()
        let lfBack = document.format.lineEnding == .lf && document.dirty
        await document.flush(reason: "test")
        log.check(edited && crlf && lfBack && (try? Data(contentsOf: url)) == Data(original.utf8),
                  "Line Endings › CRLF: an edit (\(edited)), saved with CRLF (\(crlf)); ⌘Z back to LF, saved so (\(lfBack))")
        // Chosen, kept: tabs, after a close and an open.
        document.setIndentation(.tabs(width: 2))
        await document.flush(reason: "test")
        log.check(fileText(document) == original, "and the file is as it was")
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        let again = Documents.existing(for: url)
        let kept = again?.indentation == .tabs(width: 2)
        again?.guessIndentation()
        log.check(kept && again?.indentation == .spaces(2) && NibDefaults.store.string(forKey: Document.indentationKey + url.path) == nil,
                  "a chosen indentation is kept for the file (\(kept)); Guess Indentation from the File finds 2 spaces again")
        again?.editor.textView.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }

        // Markdown: a block comment, <!-- -->.
        let scratch = Documents.scratch, sview = scratch.editor.textView
        sview.setSelectedRange(NSRange(location: (sview.string as NSString).length, length: 0))
        sview.insertText("\ncomment me \(marker)\n", replacementRange: sview.selectedRange())
        await endOfEvent(sview)
        sview.setSelectedRange(NSRange(location: (sview.string as NSString).range(of: "comment me \(marker)").location + 3, length: 0))
        sview.toggleComment(nil)
        await endOfEvent(sview)
        log.check(sview.string.contains("<!-- comment me \(marker) -->"), "in Markdown: <!-- -->")
        let menu = NSApp.mainMenu?.items.first { $0.title == "Text" }?.submenu?.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) ?? []
        log.check(menu == ["Indent", "Outdent", "Toggle Comment", "Duplicate Line", "Move Line Up", "Move Line Down", "Select Line", "Join Lines", "Go to Line…", "Go to Heading…"],
                  "the Text menu: \(menu.joined(separator: ", "))")
        // View › Indentation and View › Line Endings, as the strip's slots have them (F50).
        func viewSubmenu(_ title: String) -> [String] {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu?.items.first(where: { $0.title == title })?.submenu else { return [] }
            PaletteSession.refresh(menu)
            return menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        }
        let indentation = viewSubmenu("Indentation"), endings = viewSubmenu("Line Endings")
        log.check(indentation == ["Indent Using Tabs", "Indent Using Spaces", "Indent Width: 2", "Indent Width: 3", "Indent Width: 4", "Indent Width: 8",
                                  "Guess Indentation from the File", "Convert Indentation to Spaces", "Convert Indentation to Tabs"]
                  && endings == ["LF (Mac, Unix)", "CRLF (Windows)", "CR (Classic Mac OS)"],
                  "View › Indentation (\(indentation.count) items) and View › Line Endings (\(endings.joined(separator: ", ")))")
    }

    /// Find and replace (ED7, KB1): ⌘F from the menu with the selection in the field, the
    /// count, the other matches in the scheme's find color, ⌘G and ⇧⌘G round the end, Match
    /// Case and Whole Word, a regular expression with $1 in Replace, a bad pattern said
    /// plainly, Replace and Replace All (one undo step each), In Selection, ⌘E into the find
    /// clipboard, Escape closing the bar, and ⌘G with it closed. The file ends as it began.
    static func findScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("find-\(marker).md")
        let original = "Deploy to seedbox.\ndeploy again; redeploy later.\nDEPLOY v1.2 and v1.10\n"
        try? Data(original.utf8).write(to: url)
        let savedFind = FindSession.findClipboard
        defer {
            FindSession.findClipboard = savedFind
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isKeyWindow == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView, find = document.editor.find
        func range(_ word: String, from: Int = 0) -> NSRange {
            let s = view.string as NSString
            return s.range(of: word, options: [], range: NSRange(location: from, length: s.length - from))
        }
        func selected() -> String { (view.string as NSString).substring(with: view.selectedRange()) }
        func settle(_ label: String) async -> Bool { await waitFor(3) { find.countLabel == label } }

        // ⌘F, from Edit › Find, with "deploy" (line 2) selected.
        let findMenu = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Find" }?.submenu
        let titles = findMenu?.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) ?? []
        // With the bar's options too (the QA review's F51).
        log.check(titles == ["Find…", "Find and Replace…", "Find Next", "Find Previous", "Use Selection for Find", "Find All", "Replace", "Replace All",
                             "Regular Expression", "Match Case", "Whole Word", "In Selection"]
                  && findMenu?.item(withTitle: "Match Case")?.keyEquivalent == "c" && findMenu?.item(withTitle: "Whole Word")?.keyEquivalent == "w",
                  "Edit › Find: \(titles.joined(separator: ", "))")
        view.setSelectedRange(range("deploy"))
        let keys = ["Find…", "Find and Replace…", "Find Next", "Find Previous", "Use Selection for Find", "Replace", "Replace All"].map { title in
            guard let item = findMenu?.item(withTitle: title) else { return "none" }
            let mask = item.keyEquivalentModifierMask
            return [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")].filter { mask.contains($0.0) }.map(\.1).joined()
                + (item.keyEquivalent == "\r" ? "↩" : item.keyEquivalent.uppercased())
        }
        log.check(keys == ["⌘F", "⌥⌘F", "⌘G", "⇧⌘G", "⌘E", "⌥⌘E", "⌃⌥↩"], "on the Mac's keys and Sublime's: \(keys.joined(separator: " "))")
        // The menu acts on the window in front: this one, brought forward as a click would.
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        let front = await waitFor(5) { NSApp.isActive && view.window?.isKeyWindow == true }
        // macOS may refuse to bring a background app forward while another is in use (the
        // suite): then the text view's own action, which the menu sends when no window is in front.
        if front, let findMenu { findMenu.performActionForItem(at: findMenu.indexOfItem(withTitle: "Find…")) }
        else { view.showFind(nil) }
        let opened = await settle("2 OF 4")
        _ = await waitFor(2) { (view.window?.firstResponder as? NSTextView)?.delegate is NSTextField }
        let fieldFocused = (view.window?.firstResponder as? NSTextView)?.delegate is NSTextField
        log.check(opened && find.shown && find.query == "deploy" && fieldFocused,
                  "⌘F \(front ? "from the menu" : "(the text view's action: macOS didn't let Rune come forward)"): the bar, the selection in its field, the caret there, \(find.countLabel) (shown \(find.shown), query \(find.query.debugDescription), caret in the field \(fieldFocused), first responder \(view.window?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"))")
        // Each jump said, the focus staying in the field (the QA review's F38: VoiceOver heard nothing).
        find.next()
        let jumpSaid = Announce.said.last ?? ""
        log.check(jumpSaid.hasPrefix("3 of 4: ") || jumpSaid.hasPrefix("1 of 4: "), "a jump is said: “\(jumpSaid)”")
        find.next(backwards: true)
        let first = range("Deploy").location, redeploy = range("redeploy").location + 2
        // Every match in the find color, the current one too, and it outlined (the user, 2026-10-06:
        // shown as the selection, it went grey as the bar took the focus, at every jump). On the
        // screen: the current match's middle drawn yellow, not the selection's grey.
        let current = range("deploy"), outline = view.currentMatch.flatMap { view.matchRect($0) }
        try? await Task.sleep(for: .milliseconds(400))
        var pixel = "none"
        if let window = view.window, let frame = window.contentView?.superview, let box = view.matchRect(current),
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("find-current.png"))
            let spot = frame.convert(view.convert(NSPoint(x: box.midX, y: box.midY), to: nil), from: nil)
            let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
            let y = frame.isFlipped ? spot.y : frame.bounds.height - spot.y
            if let c = rep.colorAt(x: Int(spot.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) {
                pixel = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
            }
        }
        // Yellowish: red and green high, blue lower (the glyphs' black can fall on the middle: two tries).
        func yellowish(_ hex: String) -> Bool {
            guard hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return false }
            let r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF
            return r > 180 && g > 160 && b < r - 40
        }
        log.check(drawnColor(view, at: first, .backgroundColor) == "#FFE792" && drawnColor(view, at: first) == "#000000"
                  && drawnColor(view, at: current.location, .backgroundColor) == "#FFE792" && drawnColor(view, at: current.location) == "#000000"
                  && view.currentMatch == current && outline != nil && view.outlined(current) && yellowish(pixel),
                  "every match in the scheme's find color, black on #FFE792, the current one too, outlined (\(outline.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none")); on the screen its middle \(pixel)\(yellowish(pixel) ? ", yellow" : "")")

        // ⌘G, ⇧⌘G, round the end.
        find.next()
        let third = view.selectedRange().location == redeploy && find.countLabel == "3 OF 4"
        find.next(); find.next()
        let wrapped = view.selectedRange().location == first && find.countLabel == "1 OF 4"
        find.next(backwards: true)
        log.check(third && wrapped && selected() == "DEPLOY" && find.countLabel == "4 OF 4", "⌘G, round the end to the top, and ⇧⌘G back round")

        // The options: Match Case from Edit › Find, as ⌥⌘C does (the QA review's F51), when Nib is
        // in front to have a window's document for the menu.
        // (The menu brought up to date first, as when it opens: SwiftUI makes its items afresh, and
        // the item turns on once the window's document has the bar shown.)
        // (With Nib behind, the menu has no window's document, and its find items are off: then
        // the option is set as the bar's button sets it.)
        var itemOn = false
        if let menu = findMenu {
            itemOn = await waitFor(1) { menu.update(); return menu.items.first { $0.title == "Match Case" }?.isEnabled == true }
            if itemOn, let index = menu.items.firstIndex(where: { $0.title == "Match Case" }) { menu.performActionForItem(at: index) }
        }
        let byMenu = await waitFor(1) { find.options.matchCase }
        if !byMenu { find.options.matchCase = true }
        let cased = await waitFor(3) { find.matches.count == 2 }
        find.options.wholeWord = true
        let whole = await waitFor(3) { find.matches.count == 1 }
        find.options = SearchOptions()
        let back = await settle("4 OF 4")
        log.check(cased && whole && back && (byMenu || !itemOn),
                  "Match Case\(byMenu ? ", from Edit › Find," : "") 2 matches; and Whole Word: 1")

        // A regular expression, typed as it would be (finding as it goes), then a bad one.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        find.options.regex = true
        find.query = "v1\\.(\\d+)"
        let regex = await settle("1 OF 2")
        log.check(regex && selected() == "v1.2", "a regular expression, found as it's typed: \(selected().debugDescription), \(find.countLabel)")
        find.query = "v1\\.("
        let bad = await waitFor(3) { find.failure != nil }
        log.check(bad && find.countLabel.hasPrefix("NOT A REGULAR EXPRESSION") && document.editor.findMatches.isEmpty,
                  "a bad pattern said plainly: \(find.countLabel)")

        // From a find-only bar (⌘F) Replace and Replace All do nothing: with the field hidden they
        // replaced every match with what nobody could see, "" most often (the QA review's F1).
        find.query = "v1\\.(\\d+)"
        _ = await settle("1 OF 2")
        find.replacing = false
        find.replacement = ""
        let untouched = view.string
        find.replaceAll()
        find.replaceCurrent()
        await endOfEvent(view)
        log.check(view.string == untouched, "from a find-only bar, Replace and Replace All change nothing")

        // Replace, then Replace All, $1 kept; one undo step each.
        find.replacing = true
        find.replacement = "v2.$1"
        find.replaceCurrent()
        await endOfEvent(view)
        let one = view.string.contains("v2.2 and v1.10") && view.undoManager?.undoActionName == "Replace" && selected() == "v1.10"
        find.replaceAll()
        await endOfEvent(view)
        let all = view.string.contains("v2.2 and v2.10") && view.undoManager?.undoActionName == "Replace All" && document.notice?.hasPrefix("REPLACED 1 MATCH ") == true
        log.check(one && all, "Replace with $1, on to the next; Replace All: \(document.notice ?? "no notice")")
        view.undoManager?.undo(); await endOfEvent(view)
        let undoAll = view.string.contains("v2.2 and v1.10")
        view.undoManager?.undo(); await endOfEvent(view)
        log.check(undoAll && view.string == original, "and one undo for each")

        find.options = SearchOptions(wholeWord: true)
        find.query = "deploy"
        find.replacement = "ship"
        _ = await waitFor(3) { find.matches.count == 3 }
        find.replaceAll()
        await endOfEvent(view)
        log.check(view.string == "ship to seedbox.\nship again; redeploy later.\nship v1.2 and v1.10\n" && document.notice?.hasPrefix("REPLACED 3 MATCHES") == true,
                  "Replace All, whole words: 3")
        view.undoManager?.undo(); await endOfEvent(view)

        // In Selection: line 2 only.
        find.options = SearchOptions()
        view.setSelectedRange((view.string as NSString).lineRange(for: range("again")))
        find.inSelection = true
        let inside = await settle("2 MATCHES") || find.matches.count == 2
        find.replaceAll()
        await endOfEvent(view)
        let replaced = "Deploy to seedbox.\nship again; reship later.\nDEPLOY v1.2 and v1.10\n"
        log.check(inside && view.string == replaced, "In Selection: 2 matches there, and only they're replaced")
        // Saved, then undone and redone: each saved too. TextKit 2's undo tells the delegate
        // nothing, and an undo after a save stayed in the buffer only (the suite, 2026-10-07: an
        // app switch saved this Replace All, and the file kept it).
        await document.flush(reason: "test")
        let savedReplaced = fileText(document) == replaced
        view.undoManager?.undo(); await endOfEvent(view)
        let undoneDirty = document.dirty
        await document.flush(reason: "test")
        let savedUndo = fileText(document) == original
        view.undoManager?.redo(); await endOfEvent(view)
        await document.flush(reason: "test")
        let savedRedo = fileText(document) == replaced
        view.undoManager?.undo(); await endOfEvent(view)
        log.check(savedReplaced && undoneDirty && savedUndo && savedRedo && view.string == original,
                  "an undo after a save is saved, and a redo (saved \(savedReplaced), edited after the undo \(undoneDirty), the undo saved \(savedUndo), the redo \(savedRedo))")
        find.inSelection = false

        // In a narrow window the bar's buttons take a row of their own, and the field keeps its room
        // (the QA review's F58: the bar needed about 700 points; at 480 the field all but went).
        if let window = view.window {
            let old = window.frame
            func field(_ in: NSView) -> NSTextField? {
                if let field = `in` as? NSTextField, field.placeholderString == "Find" { return field }
                return `in`.subviews.lazy.compactMap(field).first
            }
            window.setFrame(NSRect(x: old.minX, y: old.maxY - old.height, width: 520, height: old.height), display: true)
            try? await Task.sleep(for: .milliseconds(500))
            let box = window.contentView.flatMap(field).map { $0.convert($0.bounds, to: nil) }
            let width = window.contentLayoutRect.width
            window.setFrame(old, display: true)
            log.check(box.map { $0.width >= 180 && $0.maxX <= width } == true,
                      "a narrow window (520 points): the find field keeps its room, \(Int(box?.width ?? 0)) points, the buttons in a row of their own")
        }

        // ⌘E, then Escape in the text, then ⌘G with the bar closed.
        view.setSelectedRange(range("seedbox"))
        view.useSelectionForFind(nil)
        log.check(find.query == "seedbox" && FindSession.findClipboard == "seedbox", "⌘E: the selection to find, in the find clipboard too")
        view.window?.makeFirstResponder(view)
        view.cancelOperation(nil)
        await endOfEvent(view)
        log.check(!find.shown && document.editor.findMatches.isEmpty && drawnColor(view, at: first, .backgroundColor) != "#FFE792",
                  "Escape: the bar closed, the matches no longer drawn")
        FindSession.findClipboard = "later"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.findNextMatch(nil)
        log.check(selected() == "later", "⌘G with the bar closed: the find clipboard's text (another app's ⌘E)")

        // Escape with nothing open does nothing: no word completion list (opened from here, it
        // was followed by a crash in SwiftUI's next update, three times out of three).
        view.window?.makeFirstResponder(view)
        let before = NSApp.windows.filter(\.isVisible).count
        view.cancelOperation(nil)
        try? await Task.sleep(for: .seconds(1))
        log.check(NSApp.windows.filter(\.isVisible).count == before && view.string == original, "Escape with nothing open: nothing happens")

        await document.flush(reason: "test")
        log.check(fileText(document) == original, "and the file is as it was")
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    /// Go to File and the command palette (KB2, KB3, A6): the menus and their keys (no Print
    /// holding ⌘P); Go to File's groups in order, each file once, the Nib folder's files coming
    /// in; Blit's scoring; choosing a file brings it forward; ":3" goes to line 3; the command
    /// palette's commands with their menus and keys; one chosen runs once the sheet has gone;
    /// ⌘K opens Go to File too.
    static func paletteScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("palette-\(marker).js")
        let original = "const one = 1;\nconst two = 2;\nconst three = 3;\n"
        try? Data(original.utf8).write(to: url)
        // A file of its own for the Nib Folder group (the test folder held earlier runs' files,
        // until they were cleared away and the group came up empty: the suite, 2026-10-01).
        let other = url.deletingLastPathComponent().appendingPathComponent("palette-folder-\(marker).md")
        try? Data("# In the Rune folder \(marker)\n".utf8).write(to: other)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: other)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView

        // The menus.
        func item(_ menu: String, _ title: String) -> NSMenuItem? { NSApp.mainMenu?.item(withTitle: menu)?.submenu?.item(withTitle: title) }
        let files = item("File", "Go to File…").flatMap(PaletteSession.keys), commands = item("View", "Command Palette…").flatMap(PaletteSession.keys)
        let print = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.contains { $0.title.hasPrefix("Print") } ?? true
        log.check(files == "⌘P" && commands == "⇧⌘P" && !print, "File › Go to File… \(files ?? "none"), View › Command Palette… \(commands ?? "none"), no Print")

        // Go to File.
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor(3) { view.window?.isKeyWindow == true }
        func sheet(_ up: Bool) async -> Bool { await waitFor(3) { (view.window?.attachedSheet != nil) == up } }
        /// The sheet as a picture beside the log, to look at.
        func picture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(500))
            guard let frame = view.window?.attachedSheet?.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("palette-\(name).png"))
        }
        AppDelegate.showPalette(.files, in: document)
        guard let session = document.palette, await sheet(true) else { log.check(false, "Go to File opened, a sheet on the window"); return }
        let folder = await waitFor(5) { session.entries.contains { $0.group == "Rune Folder" } }
        await picture("files")
        let groups = session.entries.map(\.group).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        let ids = session.entries.map(\.id)
        log.check(groups.first == "Scratch" && groups.prefix(2).last == "Open" && Set(ids).count == ids.count && folder
                  && session.entries.first { $0.name == url.lastPathComponent }?.group == "Open",
                  "Go to File: \(groups.joined(separator: ", ")), each file once (\(ids.count)), this file under Open")
        let ranked = CommandPalette.results(for: "palette-", in: session.entries)
        let letters = CommandPalette.results(for: "pltt", in: session.entries).first?.name
        // What VoiceOver hears as the query changes and the highlight moves (the QA review's F38).
        let spoken = CommandPalette.spokenResults(ranked), none = CommandPalette.spokenResults([])
        log.check(spoken.hasPrefix("\(ranked.count) result") && spoken.contains(url.lastPathComponent) && none == "No matches",
                  "the palette says how many and the first as it's typed in: “\(spoken)”, or “\(none)”")
        log.check(ranked.first?.name == url.lastPathComponent && CommandPalette.score("scr", "scratch-test.md") == 3
                  && CommandPalette.score("test", "scratch-test.md") == 2 && CommandPalette.score("sct", "scratch-test.md") == 1
                  && letters == url.lastPathComponent, "Blit's scoring: a prefix, then a substring, then letters in order (\(letters ?? "none"))")
        let line = session.lineEntry(":3")
        log.check(line.first?.name == "Go to Line 3" && session.lineEntry(":x").isEmpty, ":3 is a line to go to")

        // Choosing: the line, once the sheet has gone.
        if let entry = line.first { session.choose(entry) }
        document.palette = nil
        _ = await sheet(false)
        let went = await waitFor(3) { document.cursor.line == 3 }
        log.check(went && document.palette == nil, "choosing :3 closes the palette, then goes to line 3 (LN \(document.cursor.line))")

        // Choosing a file: the scratch file's window comes forward.
        AppDelegate.showPalette(.files, in: document)
        _ = await sheet(true)
        if let session = document.palette, let scratch = session.entries.first(where: { $0.group == "Scratch" }) { session.choose(scratch) }
        document.palette = nil
        let scratchFront = await waitFor(3) { AppDelegate.scratchWindow?.isVisible == true && (NSApp.keyWindow === AppDelegate.scratchWindow || !NSApp.isActive) }
        log.check(scratchFront, "choosing the scratch file brings its window forward")
        view.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor(3) { view.window?.isKeyWindow == true || !NSApp.isActive }

        // The command palette.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.window?.makeFirstResponder(view)
        AppDelegate.showPalette(.commands, in: document)
        guard let palette = document.palette, await sheet(true) else { log.check(false, "the command palette opened"); return }
        await picture("commands")
        func entry(_ name: String) -> PaletteEntry? { palette.entries.first { $0.name == name } }
        let listed = [("Toggle Comment", "Text", "⌘/"), ("Duplicate Line", "Text", "⇧⌘D"), ("Find…", "Edit › Find", "⌘F"),
                      ("Paste Clean", "Edit", "⌥⇧⌘V"), ("Sync Log", "Window", "⌥⌘L"), ("Move Line Up", "Text", "⌃⌘↑")]
            .filter { name, menu, keys in entry(name)?.detail == menu && entry(name)?.shortcut == keys }.map(\.0)
        let own = palette.entries.contains { ["Go to File…", "Command Palette…"].contains($0.name) }
        let windows = palette.entries.contains { $0.name == url.lastPathComponent }
        log.check(listed.count == 6 && !own && !windows,
                  "the command palette: every command with its menu and keys (\(listed.count) of 6 checked), not its own or the window list (\(palette.entries.count) commands)")
        // Commands that were only on the strip or a banner, and Show Scratch, in menus and so here
        // (the QA review's F44, F47).
        // (The File ones act on the window in front's file: with Nib behind, there's none.)
        let inFront = NSApp.isActive && view.window?.isKeyWindow == true
        let added = [("Show Scratch", "Window"), ("Show in Finder", "File"), ("Show Sync Log for This File", "File")]
            .filter { name, menu in entry(name)?.detail == menu }.map(\.0)
        // Go to Heading… listed, and a Revert To version or a syntax named with its menu, not bare
        // (the QA review's F76); "One Caret" without its key in its title.
        // With Nib behind, the window's commands are off and not listed (Show in Finder among them):
        // then only that nothing's named the old way.
        let named = palette.entries.contains { $0.name.hasPrefix("Syntax: ") }
        let bare = palette.entries.contains { $0.detail.hasSuffix("› Syntax") && !$0.name.hasPrefix("Syntax: ") }
        let windowCommands = entry("Show in Finder") != nil
        log.check(entry("One Caret") != nil && entry("One Caret (⎋)") == nil && !bare && (!windowCommands || (entry("Go to Heading…") != nil && named)),
                  "Go to Heading… is there, the syntaxes as “\(palette.entries.first { $0.name.hasPrefix("Syntax: ") }?.name ?? "none")”, One Caret named plainly"
                  + (windowCommands ? "" : " (Rune behind: the window's commands off, so only the names checked)"))
        log.check(added.first == "Show Scratch" && (added.count == 3 || !inFront) && entry("Show Scratch")?.shortcut != nil && entry("Restore") == nil,
                  "and the strip's commands (Restore only while deleted), and Show Scratch with its keys (\(entry("Show Scratch")?.shortcut ?? "no keys")): \(added.joined(separator: ", "))")
        let front = NSApp.isActive && view.window?.isKeyWindow == true
        if front, let duplicate = entry("Duplicate Line") {
            palette.choose(duplicate)
            document.palette = nil
            _ = await sheet(false)
            let ran = await waitFor(3) { view.string.hasPrefix("const one = 1;\nconst one = 1;\n") }
            log.check(ran, "Duplicate Line, chosen: it runs on the text once the palette has gone")
            view.undoManager?.undo()
            await endOfEvent(view)
        } else {
            // macOS didn't let Nib come forward: a command that needs no window in front.
            if let syncLog = entry("Sync Log") { palette.choose(syncLog) }
            document.palette = nil
            _ = await sheet(false)
            let ran = await waitFor(3) { NSApp.windows.contains { $0.identifier?.rawValue.contains("sync-log") == true && $0.isVisible } }
            log.check(ran, "Sync Log, chosen: its window opens once the palette has gone (Rune not in front, so not a text command)")
            NSApp.windows.first { $0.identifier?.rawValue.contains("sync-log") == true }?.performClose(nil)
        }

        // ⌘K.
        _ = await waitFor(2) { document.palette == nil }
        if let window = view.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                  windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k",
                                                                  isARepeat: false, keyCode: 40) {
            NSApp.postEvent(event, atStart: false)
        }
        let byK = await waitFor(3) { Documents.all.contains { $0.palette?.kind == .files } }
        log.check(byK, "⌘K opens Go to File too")
        for open in Documents.all { open.palette = nil }
        _ = await waitFor(2) { Documents.all.allSatisfy { $0.palette == nil } }

        await document.flush(reason: "test")
        log.check(fileText(document) == original, "and the file is as it was")
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    /// Line numbers and invisibles (ED6): TextKit 2 kept; one number a line, a wrapped line
    /// numbered once, the empty last line too, the caret's brighter; LN, COL from the line
    /// index matching a count from the top, through edits; the gutter widening past 999 lines;
    /// the View menu turning each off and on; dots and arrows for spaces and tabs. The window
    /// is saved as a picture beside the log.
    static func gutterScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let defaults = NibDefaults.store
        let saved = (defaults.object(forKey: "editorLineNumbers"), defaults.object(forKey: "editorInvisibles"))
        defaults.removeObject(forKey: "editorLineNumbers")
        defaults.removeObject(forKey: "editorInvisibles")
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("gutter-\(marker).txt")
        let long = String(repeating: "a long line that wraps across the window ", count: 12)
        let original = "alpha \(marker)\n\tbeta  gamma\n\(long)\n\nlast line\n"
        try? Data(original.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            for (key, value) in [("editorLineNumbers", saved.0), ("editorInvisibles", saved.1)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url), let window = document.editor.textView.window else { log.check(false, "the file opened"); return }
        let editor = document.editor, view = editor.textView
        window.setFrame(NSRect(x: 120, y: 160, width: 640, height: 420), display: true)
        func redraw() async {
            editor.ruler?.display()
            view.display()
            try? await Task.sleep(for: .milliseconds(150))
        }
        func picture(_ name: String) {
            guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("gutter-\(name).png"))
        }
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "last line").location, length: 0))
        await redraw()
        guard let ruler = editor.ruler else { log.check(false, "line numbers are on by default"); return }
        log.check(view.textLayoutManager != nil && editor.scrollView.rulersVisible, "line numbers on by default, the text view still on TextKit 2")
        log.check(ruler.drawn == [1, 2, 3, 4, 5, 6] && ruler.drawnCurrent == 5,
                  "one number a line, the wrapped line once, the empty last line too, the caret's brighter: \(ruler.drawn), bright \(ruler.drawnCurrent.map(String.init) ?? "none")")
        picture("numbers")

        // LN, COL from the index, through edits, against a count from the top.
        func counted(_ location: Int) -> (Int, Int) {
            let before = (view.string as NSString).substring(to: location)
            let lines = before.components(separatedBy: "\n")
            return (lines.count, (lines.last! as NSString).length + 1)
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("new first line\n\n", replacementRange: NSRange(location: 0, length: 0))
        let probes = [0, 5, 20, (view.string as NSString).length / 2, (view.string as NSString).length]
        let agree = probes.allSatisfy { editor.position(of: $0) == counted($0) }
        await redraw()
        log.check(agree && editor.lineIndex.lineCount == 8 && ruler.drawn.first == 1 && ruler.drawn.last == 8,
                  "LN, COL from the line index match a count from the top, after an edit (\(editor.lineIndex.lineCount) lines, drawn \(ruler.drawn.first ?? 0)-\(ruler.drawn.last ?? 0))")
        let thin = ruler.ruleThickness
        view.insertText(String(repeating: "x\n", count: 1_000), replacementRange: NSRange(location: 0, length: 0))
        await redraw()
        let wider = ruler.ruleThickness > thin
        view.undoManager?.undo()
        await endOfEvent(view)
        view.undoManager?.undo()
        await endOfEvent(view)
        await redraw()
        log.check(wider && editor.lineIndex.lineCount == 6 && view.string == original,
                  "past 999 lines the gutter widens (\(Int(thin)) to wider), and undo puts it all back (\(editor.lineIndex.lineCount) lines)")

        // The View menu.
        let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu
        func choose(_ title: String) async -> Bool {
            guard let menu = viewMenu else { return false }
            PaletteSession.refresh(menu)   // as when the menu opens: SwiftUI names the items afresh
            guard let item = menu.item(withTitle: title) else { return false }
            menu.performActionForItem(at: menu.index(of: item))
            try? await Task.sleep(for: .milliseconds(300))
            return true
        }
        let hid = await choose("Hide Line Numbers")
        let off = !editor.scrollView.rulersVisible && editor.ruler == nil && !defaults.bool(forKey: "editorLineNumbers")
        let showed = await choose("Show Line Numbers")
        log.check(hid && off && showed && editor.ruler != nil && editor.scrollView.rulersVisible && view.textLayoutManager != nil,
                  "View › Hide Line Numbers, then Show Line Numbers")

        // Invisibles.
        let shown = await choose("Show Invisibles")
        await redraw()
        picture("invisibles")
        let marks = view.invisiblesDrawn
        let spaces = (original as NSString).components(separatedBy: " ").count - 1
        log.check(shown && view.showsInvisibles && marks.arrows == 1 && marks.dots == spaces,
                  "View › Show Invisibles: \(marks.dots) dots for \(spaces) spaces, \(marks.arrows) arrow for the tab")
        _ = await choose("Hide Invisibles")
        log.check(!view.showsInvisibles, "and Hide Invisibles")

        await document.flush(reason: "test")
        log.check(fileText(document) == original, "and the file is as it was (nothing drawn is in the text)")
        window.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    /// Tidying on ⌘S (ED6): off by default; with the settings on, nothing in a file not edited
    /// here; Nib's own save after typing leaves a typed trailing space alone; ⌘S trims and ends
    /// the file with a newline as one undo step, the strip says so, the caret stays on its line,
    /// and the file on disk is the tidied text; ⌘Z puts it all back.
    static func tidyScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let defaults = NibDefaults.store
        let keys = ["saveTrimsTrailingWhitespace", "saveEnsuresFinalNewline"]
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("tidy-\(marker).txt")
        let original = "keep \(marker)  \n\tindented\t\nlast"
        try? Data(original.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView

        await document.saveNow()
        log.check(view.string == original && fileText(document) == original, "off by default: ⌘S changes nothing")
        keys.forEach { defaults.set(true, forKey: $0) }
        await document.saveNow()
        log.check(view.string == original && fileText(document) == original, "on, in a file not edited here: ⌘S still changes nothing")

        // Typing a trailing space; Nib's own save a moment later leaves it.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await type(" line ", into: document)
        let typed = original + " line "
        let autosaved = await waitFor(8) { fileText(document) == typed && !document.dirty }
        log.check(autosaved && view.string == typed, "Rune's own save after typing keeps the space just typed at the end")

        // ⌘S.
        await endOfEvent(view)
        await document.saveNow()
        let tidied = "keep \(marker)\n\tindented\nlast line\n"
        let caretLine = document.cursor.line
        log.check(view.string == tidied && view.undoManager?.undoActionName == "Trim Whitespace and Add Newline" && caretLine == 3,
                  "⌘S: trailing whitespace off 3 lines, a final newline, one undo step, the caret still on its line (LN \(caretLine))")
        log.check(document.notice == "TRIMMED TRAILING WHITESPACE ON 3 LINES · ADDED A FINAL NEWLINE · ⌘Z UNDOES", "the strip says so: \(document.notice ?? "nothing")")
        let onDisk = await waitFor(5) { fileText(document) == tidied }
        log.check(onDisk, "and the file on disk is the tidied text")
        await endOfEvent(view)
        view.undoManager?.undo()
        await endOfEvent(view)
        log.check(view.string == typed, "⌘Z puts back the whitespace and takes the newline off, in one step")

        await document.flush(reason: "test")
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    /// The menu bar extra (§5.7, AP3, A10): the item there by default, the nib a fixed width;
    /// still when synced, its line marching once an upload has waited more than 3 s; the red ✕
    /// beside it while a file holds a conflict block; the scratch card's lines; a click opening
    /// the 320 pt panel; Settings › General taking it away and putting it back. The item and
    /// the panel are saved as pictures beside the log.
    static func menuBarScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        let defaults = NibDefaults.store
        defaults.removeObject(forKey: "showMenuBarExtra")
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()

        // Nib's status item and panel.
        func statusButton() -> NSStatusBarButton? { MenuBarController.shared.button }
        /// The item as drawn, to compare.
        func picture(saving name: String? = nil) -> Data? {
            guard let view = statusButton(), let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let name { try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png")) }
            return rep.tiffRepresentation
        }
        let shown = await waitFor(5) { statusButton() != nil && picture() != nil }
        _ = picture(saving: "menubar-item")
        log.check(shown, "the menu bar item is there by default")

        // The art.
        let widths = Set([nil, 0, 1, 2].map { MenuBarMark.image(NibMark.rows(frame: $0), width: NibMark.width).size.width })
        log.check(NibMark.rows(frame: nil).count == 10 && widths.count == 1 && NibMark.line(frame: nil) == "#########"
                  && NibMark.line(frame: 0) == "##.##.##." && NibMark.line(frame: 1) == ".##.##.##",
                  "the ᚱ, a fixed width, its line solid or in dashes a step further right each frame")

        // Still when synced; marching once an upload has waited more than 3 s.
        let still = picture()
        try? await Task.sleep(for: .milliseconds(400))
        log.check(still != nil && picture() == still, "still while synced (\(document.state.line))")
        defaults.set(true, forKey: "NibHoldUploads")
        Document.stallAfter = 2
        Document.stallCheckEvery = 0.5
        await type("\n- menu bar \(marker)\n", into: document)
        _ = await waitFor(8) { if case .saved = document.state { true } else { false } }
        // Not through typing's pause, which the upload waits for by design: only once it's 3 s past
        // due (the QA review's F43: it marched from the save, after most pauses in typing).
        try? await Task.sleep(for: .milliseconds(1_500))
        log.check(picture() == still && !MenuBarController.overdue([document]), "through typing's pause, before its upload is due, the line stays still")
        try? await Task.sleep(for: .milliseconds(5_000))
        let a = picture()
        try? await Task.sleep(for: .milliseconds(250))
        log.check(a != nil && a != picture(), "its line marches once an upload is more than 3 s past due (\(document.state.line))")
        // Saved here, the network up, iCloud not uploading it: the strip says how long (§4.5; F42).
        log.check(document.statusLine.contains(" · ICLOUD HASN'T STARTED UPLOADING (1 MIN)"), "and the strip says iCloud hasn't started uploading it: \(document.statusLine)")
        Document.stallAfter = 60
        Document.stallCheckEvery = 15
        defaults.set(true, forKey: "NibReduceMotion")
        try? await Task.sleep(for: .milliseconds(400))
        let calmA = picture(saving: "menubar-item-reduce-motion")
        try? await Task.sleep(for: .milliseconds(500))
        log.check(calmA != nil && calmA == picture() && calmA != still, "with Reduce Motion it doesn't march: still, in dashes, while the upload waits")
        defaults.removeObject(forKey: "NibReduceMotion")
        defaults.removeObject(forKey: "NibHoldUploads")
        await document.flush(reason: "test")
        await waitSynced(document, 20)
        try? await Task.sleep(for: .milliseconds(400))
        let calm = picture()
        try? await Task.sleep(for: .milliseconds(400))
        log.check(calm == picture() && isSynced(document), "and still again once it's synced")

        // The card.
        let card = MenuBarState.card(document)
        log.check(card.first == document.url.lastPathComponent.uppercased() && card[1] == document.statusLine && card[2].hasPrefix("SAVED ")
                  && card[2].contains(" · UPLOADED ") && !card[2].hasSuffix("—"),
                  "the scratch card: \(card.joined(separator: " / "))")

        // A conflict block in a file: the red ✕ beside the nib.
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("menubar-\(marker).txt")
        try? Data("<<<<<<< A · 10:00\nours \(marker)\n=======\ntheirs\n>>>>>>> B · 10:00\n".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        let plainWidth = statusButton()?.image?.size.width ?? 0
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.blocks.isEmpty == false }
        document.editor.textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))   // a change: the label looks again
        // The ✕ makes the image wider, and it's no longer a template (it keeps its red).
        let marked = await waitFor(5) { (statusButton()?.image?.size.width ?? 0) > plainWidth && statusButton()?.image?.isTemplate == false }
        _ = picture(saving: "menubar-item-conflict")
        log.check(marked, "a conflict block in an open file: the red ✕ beside the ᚱ (\(plainWidth) pt, then \(statusButton()?.image?.size.width ?? 0))")
        Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
        document.editor.textView.undoManager?.undo()

        // The panel: a click on the item.
        statusButton()?.performClick(nil)
        let opened = await waitFor(5) { MenuBarController.shared.panel?.isVisible == true }
        try? await Task.sleep(for: .milliseconds(500))
        if let content = MenuBarController.shared.panel?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("menubar-panel.png"))
        }
        let width = MenuBarController.shared.panel?.frame.width ?? 0
        let below = (MenuBarController.shared.panel?.frame.maxY ?? .infinity) <= (statusButton()?.window?.frame.minY ?? 0)
        log.check(opened && width == 320 && below, "a click opens the panel under the item, \(Int(width)) pt wide")
        MenuBarController.shared.panel?.cancelOperation(nil)
        log.check(MenuBarController.shared.panel?.isVisible == false, "and Escape closes it")

        // The keys, as in a menu (the QA review's F82: it took none but Escape): ↓ to Clean
        // Clipboard, ↑ back to Show Scratch, Return chooses it (the panel closes; it's harmless).
        statusButton()?.performClick(nil)
        _ = await waitFor(5) { MenuBarController.shared.panel?.isVisible == true }
        try? await Task.sleep(for: .milliseconds(300))
        func key(_ code: UInt16, _ character: Int) {
            guard let panel = MenuBarController.shared.panel, let scalar = UnicodeScalar(character) else { return }
            let characters = String(Character(scalar))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: code == 36 ? [] : [.numericPad, .function],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                                            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
        }
        var lit: [String] = []
        for _ in 0..<6 where NibMenuBarPanel.litTitle != "Clean Clipboard" {
            key(125, 0xF701)   // ↓
            _ = await waitFor(1) { NibMenuBarPanel.litTitle != lit.last }
            lit.append(NibMenuBarPanel.litTitle ?? "none")
        }
        key(126, 0xF700)   // ↑
        let up = await waitFor(1) { NibMenuBarPanel.litTitle == "Show Scratch" }
        key(36, 0x0D)   // Return
        let chosen = await waitFor(3) { MenuBarController.shared.panel?.isVisible == false }
        log.check(lit.last == "Clean Clipboard" && up && chosen,
                  "the panel by the keys, as a menu: ↓ lit \(lit.joined(separator: ", ")), ↑ Show Scratch (\(up)), Return chose it (the panel closed: \(chosen))")

        // Settings › General.
        defaults.set(false, forKey: "showMenuBarExtra")
        let gone = await waitFor(5) { statusButton() == nil }
        defaults.removeObject(forKey: "showMenuBarExtra")
        let back = await waitFor(5) { statusButton() != nil }
        log.check(gone && back, "Settings › General takes it out of the menu bar and puts it back (gone \(gone), back \(back))")
        await document.flush(reason: "test")
    }

    /// The first run (AP5, AP2, SC2): the welcome window at launch; the scratch step finding the
    /// file, refusing one outside the test folder and taking another for when Nib reopens; the
    /// look step's summary of Sublime's settings; the shortcut fields (new keys, Escape, Delete,
    /// ⇧ alone refused, keys another action has refused) with their warnings (another app holds
    /// them, macOS's own); the Edit menu showing the keys; open at login (a stand-in: the real one
    /// would add this build to the Mac's Login Items); Done; and a scratch file not made until
    /// the welcome window says so. Its settings are put back after (the scenarios' own store),
    /// and its keys let go: they're the Nib in daily use's.
    static func firstRunScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let defaults = NibDefaults.store
        let kept = [FirstRun.doneKey, "scratchPath", "settingsTab"] + GlobalShortcuts.Action.allCases.map { "shortcut." + $0.rawValue }
        let saved = kept.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            GlobalShortcuts.shared.suspend()
        }
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()
        let model = FirstRun.shared
        let shortcuts = GlobalShortcuts.shared
        func picture(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(400))
            guard let view = model.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }

        // Step 1: the scratch file.
        let shown = await waitFor(5) { model.window?.isVisible == true }
        log.check(shown && model.step == .scratch, "the welcome window at the first launch, at step 1")
        _ = await waitFor(12) { model.scratchFound != nil }
        log.check(model.scratchFound == true && model.scratchReady && !document.awaitingFirstRun,
                  "step 1 finds the scratch file: \(document.url.lastPathComponent) in \(ScratchLocation.place(of: document.url))")
        await picture("firstrun-1")
        model.use(URL(fileURLWithPath: NSHomeDirectory() + "/Documents/scratch-\(marker).md"))   // a path only: never read
        log.check(model.chosen == nil && model.message?.contains("only test files") == true, "a file outside the test folder is refused: \(model.message ?? "no message")")
        // Said, not only shown beside the button (the QA review's F62).
        let saidRefusal = await waitFor(2) { model.message.map { Announce.said.contains($0) } == true }
        log.check(saidRefusal, "and the refusal is said to VoiceOver as it shows")
        let other = document.url.deletingLastPathComponent().appendingPathComponent("firstrun-\(marker).md")
        model.use(other)
        log.check(model.chosen == other && model.message == nil, "another test file is taken, for when Rune reopens")
        await picture("firstrun-1-chosen")
        model.keepCurrent()
        model.use(document.url)
        log.check(model.chosen == nil && model.scratchReady, "and Keep, or choosing the one open, goes back to it")

        // Step 2: the look.
        model.step = .look
        await picture("firstrun-2")
        log.check(model.sublime.found != nil || model.sublime.failure != nil, "step 2 says what Sublime Text has: \(model.sublime.found ?? model.sublime.failure ?? "")")

        // Step 3: the keys.
        model.step = .keys
        await picture("firstrun-3")
        // The Nib in daily use, running beside this one, holds its keys, as Nib takes them,
        // exclusively: this one can't have them too, and says another app holds them. Such a key
        // counts as registered here (2026-10-01).
        let otherNib = NSRunningApplication.runningApplications(withBundleIdentifier: "com.banastas.nib").contains { $0.processIdentifier != getpid() }
        func registered(_ ids: Set<UInt32>) -> Bool {
            HotKey.registered.isSubset(of: ids) && ids.allSatisfy { id in
                HotKey.registered.contains(id) || otherNib && GlobalShortcuts.Action.allCases.first { $0.hotKeyID == id }
                    .flatMap { shortcuts.warnings[$0] }?.hasPrefix("Another app holds") == true
            }
        }
        for action in GlobalShortcuts.Action.allCases { shortcuts.reset(action) }
        let beside = otherNib ? "; the Rune in daily use holds \(GlobalShortcuts.Action.allCases.filter { shortcuts.warnings[$0] != nil }.map(\.title))" : ""
        log.check(shortcuts.shortcut(.showScratch)?.description == "⌥Space" && shortcuts.shortcut(.cleanClipboard)?.description == "⌃⌥⌘V"
                  && shortcuts.shortcut(.appendClipboard) == nil && registered([1, 2]),
                  "Rune's own keys: ⌥Space and ⌃⌥⌘V, none for Append, and both registered (\(HotKey.registered.sorted())\(beside))")
        func recorder(_ action: GlobalShortcuts.Action) -> ShortcutRecorder? {
            func find(_ view: NSView) -> ShortcutRecorder? {
                if let field = view as? ShortcutRecorder, field.shortcutAction == action { return field }
                return view.subviews.lazy.compactMap(find).first
            }
            return model.window?.contentView.flatMap(find)
        }
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags, _ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: model.window?.windowNumber ?? 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))!
        }
        let controlOptionShiftK = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey | shiftKey))
        if let field = recorder(.showScratch) {
            field.performClick(nil)
            log.check(field.recording && field.title == "Type the keys…" && HotKey.registered.isEmpty, "a click on Show Scratch's field listens, with Rune's shortcuts off meanwhile")
            field.keyDown(with: key(kVK_ANSI_K, .shift, "K"))
            log.check(field.recording && shortcuts.shortcut(.showScratch)?.description == "⌥Space", "⇧K alone isn't taken: it would take a capital K from every app")
            field.keyDown(with: key(kVK_ANSI_K, [.control, .option, .shift], "K"))
            log.check(!field.recording && shortcuts.shortcut(.showScratch) == controlOptionShiftK && field.title == "⌃⌥⇧K" && registered([1, 2]),
                      "⌃⌥⇧K pressed: Show Scratch's new keys, registered, shown as \(field.title)")
            field.performClick(nil)
            field.keyDown(with: key(kVK_Escape, [], "\u{1B}"))
            log.check(!field.recording && shortcuts.shortcut(.showScratch) == controlOptionShiftK, "Escape keeps them")
            field.performClick(nil)
            field.keyDown(with: key(kVK_Delete, [], "\u{7F}"))
            log.check(shortcuts.shortcut(.showScratch) == nil && field.title == "None" && registered([2]), "Delete clears them: none, and not registered")
            shortcuts.reset(.showScratch)
            // Keys another action has, typed into the field: refused, and the reason stays (the QA
            // review's F24: stopping wiped it as it was set).
            field.performClick(nil)
            field.keyDown(with: key(kVK_ANSI_V, [.control, .option, .command], "v"))
            log.check(!field.recording && shortcuts.shortcut(.showScratch)?.description == "⌥Space" && shortcuts.warnings[.showScratch]?.contains("Clean Clipboard already uses") == true,
                      "keys another action has, typed into the field: refused, saying why (\(shortcuts.warnings[.showScratch] ?? "no warning"))")
            // Keys every app uses: refused, saying why (F23: ⌘C was taken, and ⌥E, the accent key).
            field.performClick(nil)
            field.keyDown(with: key(kVK_ANSI_C, .command, "c"))
            let copy = shortcuts.warnings[.showScratch] ?? ""
            field.performClick(nil)
            field.keyDown(with: key(kVK_ANSI_E, .option, "´"))
            let accent = shortcuts.warnings[.showScratch] ?? ""
            log.check(shortcuts.shortcut(.showScratch)?.description == "⌥Space" && copy.hasPrefix("⌘C is a key apps use") && accent.hasPrefix("⌥E types or moves"),
                      "keys every app uses are refused, saying why: “\(copy)” and “\(accent)”")
            shortcuts.reset(.showScratch)
        } else {
            log.check(false, "Show Scratch's field is in the window")
        }
        shortcuts.set(GlobalShortcuts.Action.cleanClipboard.standard, for: .showScratch)
        log.check(shortcuts.shortcut(.showScratch)?.description == "⌥Space" && shortcuts.warnings[.showScratch]?.contains("Clean Clipboard already uses ⌃⌥⌘V") == true,
                  "keys another action has are refused: \(shortcuts.warnings[.showScratch] ?? "no warning")")
        shortcuts.reset(.showScratch)

        // Another app holding the keys.
        if let holder = defaults.string(forKey: "NibHotKeyHolder"), FileManager.default.isExecutableFile(atPath: holder) {
            let keys = Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | shiftKey))
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: holder)
            process.arguments = ["\(keys.keyCode)", "\(keys.modifiers)", "20"]
            process.standardOutput = output
            try? process.run()
            let held = await Task.detached { String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "" }.value
            shortcuts.set(keys, for: .appendClipboard)
            await picture("firstrun-3-taken")
            // All of the step in the window, and the window on the Air's screen (the QA review's
            // F22: a fixed 580 points hid step 3's notifications note under its footer).
            // (Fitted by `FirstRun.fit` after a change, never in a layout pass: left to SwiftUI, the
            // warning's arrival looped AppKit's layout until it threw.)
            if let window = model.window {
                _ = await waitFor(2) { model.wanted <= window.contentLayoutRect.height + 1 }
                let needs = model.wanted, has = window.contentLayoutRect.height
                log.check(needs > 0 && needs <= has + 1 && window.frame.height <= 860,
                          "the welcome window holds all of step 3, a warning showing (\(Int(needs)) points in \(Int(has))), \(Int(window.frame.height)) points tall")
            }
            log.check(held.hasPrefix("held") && shortcuts.warnings[.appendClipboard]?.hasPrefix("Another app holds ⌃⌥⇧J") == true && !HotKey.registered.contains(3),
                      "keys another app holds: \(shortcuts.warnings[.appendClipboard] ?? "no warning") (the other app: \(held.trimmingCharacters(in: .whitespacesAndNewlines)))")
            process.terminate()
            shortcuts.reset(.appendClipboard)
        } else {
            log.line("skipped: keys another app holds (no -NibHotKeyHolder)")
        }
        // macOS's own: Spotlight's ⌘Space, where it's on.
        let spotlight = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))
        if HotKey.usedByMacOS(spotlight) {
            shortcuts.set(spotlight, for: .appendClipboard)
            log.check(shortcuts.warnings[.appendClipboard]?.hasPrefix("macOS uses ⌘Space itself") == true, "keys macOS keeps: \(shortcuts.warnings[.appendClipboard] ?? "no warning")")
            shortcuts.reset(.appendClipboard)
        } else {
            log.line("skipped: macOS doesn't keep ⌘Space on this Mac")
        }
        log.check(shortcuts.warnings.values.allSatisfy { otherNib && $0.hasPrefix("Another app holds") } && registered([1, 2]),
                  "back to Rune's own keys, with nothing in their way\(otherNib ? " but the Rune in daily use" : "")")

        // The Edit menu shows Clean Clipboard's keys, whatever they are.
        func editItem(_ title: String) -> NSMenuItem? {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu else { return nil }
            PaletteSession.refresh(menu)
            return menu.items.first { $0.title == title }
        }
        let standardKeys = editItem("Clean Clipboard").flatMap(PaletteSession.keys(of:))
        shortcuts.set(Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey | cmdKey)), for: .cleanClipboard)
        _ = await waitFor(3) { editItem("Clean Clipboard").flatMap(PaletteSession.keys(of:)) == "⌃⌥⌘B" }
        let changedKeys = editItem("Clean Clipboard").flatMap(PaletteSession.keys(of:))
        shortcuts.reset(.cleanClipboard)
        log.check(standardKeys == "⌃⌥⌘V" && changedKeys == "⌃⌥⌘B", "Edit › Clean Clipboard shows its keys: \(standardKeys ?? "none"), then \(changedKeys ?? "none")")

        // Open at login.
        let login = LoginItem.shared
        login.set(true)
        let on = login.enabled
        login.set(false)
        log.check(on && !login.enabled && login.failure == nil, "Open Rune when you log in turns on and off (a stand-in; macOS says this build's login item is \(["not registered", "on", "waiting for approval", "not found"][min(3, SMAppService.mainApp.status.rawValue)]))")

        // Done.
        model.finish()
        let done = await waitFor(3) { model.window == nil && AppDelegate.scratchWindow?.isVisible == true }
        log.check(done && defaults.integer(forKey: FirstRun.doneKey) == 1, "Done: the welcome window goes, the scratch window shows, and it's done on this Mac")
        model.show()
        let again = await waitFor(3) { model.window?.isVisible == true }
        model.window?.close()
        log.check(again && model.window == nil, "Help › Welcome to Rune shows it again")

        // Not there yet: looked for again while the window's open, for another Mac's may be on its
        // way (the QA review's F26: it looked once and offered Create).
        let coming = folder.appendingPathComponent("coming-\(marker).md")
        FirstRun.lookingFor = coming
        FirstRun.lookEvery = 0.5
        model.show()
        _ = await waitFor(5) { model.scratchFound == false }
        let missing = model.scratchFound == false
        try? Data("# Coming \(marker)\n".utf8).write(to: coming)
        let cameIn = await waitFor(5) { model.scratchFound == true }
        model.window?.close()
        FirstRun.lookingFor = nil
        FirstRun.lookEvery = 2
        try? FileManager.default.removeItem(at: coming)
        log.check(missing && cameIn, "a scratch file not there yet is looked for again while the window's open, and found once it comes")

        // Settings › General has them too, with Append's.
        defaults.set("general", forKey: "settingsTab")
        AppDelegate.openSettings()
        func fields(in view: NSView) -> [ShortcutRecorder] {
            if let field = view as? ShortcutRecorder { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        func settingsWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0 !== model.window && !fields(in: $0.contentView ?? NSView()).isEmpty }
        }
        _ = await waitFor(5) { settingsWindow().map { fields(in: $0.contentView!).count == GlobalShortcuts.Action.allCases.count } ?? false }
        let found = settingsWindow().map { fields(in: $0.contentView!).map(\.shortcutAction) } ?? []
        if let window = settingsWindow(), let view = window.contentView {
            try? await Task.sleep(for: .milliseconds(400))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-general.png"))
            }
            window.close()
        }
        log.check(Set(found) == Set(GlobalShortcuts.Action.allCases), "Settings › General has the three shortcuts' fields: \(found.map(\.title).joined(separator: ", "))")

        // No scratch file yet: nothing is made until the welcome window says so.
        try? FileManager.default.removeItem(at: other)
        let fresh = Document(url: other)
        fresh.awaitFirstRun()
        try? await Task.sleep(for: .milliseconds(300))
        let waiting = !FileManager.default.fileExists(atPath: other.path) && fresh.state.line.contains("NO SCRATCH FILE YET") && !fresh.editor.textView.isEditable
        await fresh.open()
        _ = await waitFor(10) { fresh.ready }
        log.check(waiting && FileManager.default.fileExists(atPath: other.path) && fresh.editor.textView.isEditable && fresh.ready,
                  "no scratch file: none made while the welcome window waits, then made when it says so")
        await fresh.close()
        try? FileManager.default.removeItem(at: other)
    }

    /// The `rune` command-line tool (AP4), the real binary (-NibCLI) against this Rune: a file at a
    /// line; `-w` waiting until the window closes, the typing in the file by then; standard
    /// input as an untitled buffer, and at the end of the scratch file (undone after);
    /// `--scratch`; a file outside the test folder refused and a folder refused, with exit 1;
    /// an unknown option, exit 2; and a waiting `-w` let go when Nib quits.
    static func cliScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        guard let tool = NibDefaults.store.string(forKey: "NibCLI"), FileManager.default.isExecutableFile(atPath: tool) else {
            log.check(false, "the rune tool to run (-NibCLI)")
            return
        }
        let folder = document.url.deletingLastPathComponent()
        let made = (1...3).map { folder.appendingPathComponent("cli-\(marker)-\($0).txt") }
        for (n, url) in made.enumerated() {
            try? Data((1...6).map { "file \(n + 1) line \($0) \(marker)" }.joined(separator: "\n").appending("\n").utf8).write(to: url)
        }
        var untitled: URL?
        defer {
            for url in made + [untitled].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
                NibDefaults.store.removeObject(forKey: "selection:" + url.path)
                if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            }
        }

        /// Runs the tool; the result once it exits (or nil after `seconds`).
        func start(_ arguments: [String], input: String? = nil) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.currentDirectoryURL = folder
            process.environment = ["NIB_SCENARIOS": "1", "NIB_NO_LAUNCH": "1", "NIB_NO_ACTIVATE": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
            return process
        }
        func finish(_ process: Process, _ seconds: Double = 15) async -> (status: Int32, error: String)? {
            guard await waitFor(seconds, { !process.isRunning }) else { process.terminate(); return nil }
            let error = (process.standardError as? Pipe).flatMap { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) } ?? ""
            return (process.terminationStatus, error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func run(_ arguments: [String], input: String? = nil) async -> (status: Int32, error: String)? {
            await finish(start(arguments, input: input))
        }
        func caretLine(_ url: URL) -> Int? {
            guard let open = Documents.existing(for: url) else { return nil }
            return open.editor.lineIndex.line(at: open.editor.textView.selectedRange().location)
        }
        func close(_ url: URL) async {
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil }
        }

        // A file at a line, by a path relative to the shell's folder.
        let atLine = await run([made[0].lastPathComponent + ":4"])
        _ = await waitFor(10) { caretLine(made[0]) == 4 }
        log.check(atLine?.status == 0 && Documents.existing(for: made[0])?.ready == true && caretLine(made[0]) == 4,
                  "rune file:4 opens it with the caret on line 4 (exit \(atLine.map { "\($0.status)" } ?? "none"), line \(caretLine(made[0]) ?? 0))")
        await close(made[0])

        // -w: waits until the window closes, and the typing is in the file by then.
        let waiter = start(["-w", made[1].path])
        _ = await waitFor(10) { Documents.existing(for: made[1])?.ready == true && CLIBridge.waiters(for: made[1]) == 1 }
        let opened = Documents.existing(for: made[1])
        try? await Task.sleep(for: .milliseconds(1_500))
        log.check(opened?.ready == true && waiter.isRunning, "rune -w opens the file and waits")
        if let opened { await type("typed while rune -w waits \(marker)\n", into: opened) }
        await close(made[1])
        let waited = await finish(waiter, 10)
        let saved = (try? String(contentsOf: made[1], encoding: .utf8)) ?? ""
        log.check(waited?.status == 0 && saved.contains("typed while rune -w waits \(marker)"),
                  "and returns when its window closes (exit \(waited.map { "\($0.status)" } ?? "none")), the typing in the file")

        // Standard input as an untitled buffer.
        let before = Set(Documents.all.map(\.url))
        let piped = await run([], input: "piped into rune \(marker)\nsecond line\n")
        _ = await waitFor(10) { Documents.all.contains { !before.contains($0.url) && $0.untitled && $0.ready && !$0.editor.textView.string.isEmpty } }
        let buffer = Documents.all.first { !before.contains($0.url) && $0.untitled }
        untitled = buffer?.url
        log.check(piped?.status == 0 && buffer?.editor.textView.string == "piped into rune \(marker)\nsecond line\n",
                  "cmd | rune: an untitled buffer with its text (\(buffer?.url.lastPathComponent ?? "none"): exit \(piped.map { "\($0.status) \($0.error)" } ?? "none"), \(buffer?.editor.textView.string.debugDescription ?? "no text"))")
        if let url = buffer?.url { await close(url) }

        // Standard input at the end of the scratch file, then undone.
        let length = (document.editor.textView.string as NSString).length
        let appended = await run(["-a"], input: "appended by rune -a \(marker)\n")
        _ = await waitFor(5) { document.editor.textView.string.hasSuffix("appended by rune -a \(marker)\n") }
        log.check(appended?.status == 0 && document.editor.textView.string.hasSuffix("appended by rune -a \(marker)\n")
                  && document.editor.textView.selectedRange().location <= length,
                  "cmd | rune -a: at the end of the scratch file, the caret where it was")
        if document.editor.textView.string.hasSuffix("appended by rune -a \(marker)\n") { document.editor.textView.undoManager?.undo() }
        log.check((document.editor.textView.string as NSString).length == length, "and ⌘Z takes it out again")
        let nothing = await run(["-a"], input: "")
        log.check(nothing?.status == 1 && nothing?.error == "rune: nothing on standard input to append", "rune -a with nothing piped in: \(nothing?.error ?? "no answer")")

        // --scratch.
        AppDelegate.scratchWindow?.orderOut(nil)
        let shown = await run(["--scratch"])
        _ = await waitFor(5) { AppDelegate.scratchWindow?.isVisible == true }
        log.check(shown?.status == 0 && AppDelegate.scratchWindow?.isVisible == true, "rune --scratch shows the scratch window")

        // Refused: a file outside the test folders (a path only: never read), and a folder.
        let outside = NSHomeDirectory() + "/Documents/cli-\(marker).txt"
        let refused = await run([outside])
        log.check(refused?.status == 1 && refused?.error.contains("isn't a test file") == true && Documents.existing(for: URL(fileURLWithPath: outside)) == nil,
                  "a file outside the test folder isn't opened: \(refused?.error ?? "no answer") (exit \(refused.map { "\($0.status)" } ?? "none"))")
        let directory = await run([folder.path])
        log.check(directory?.status == 1 && directory?.error.contains("is a folder") == true, "nor a folder: \(directory?.error ?? "no answer")")

        // A path with no file (the QA review's F3): in a folder that isn't there, refused (it exited
        // 0 before); in one that is, made empty to open, and gone again when closed still empty, with
        // nothing kept for it; and a gone file chosen from a list isn't made again.
        let nowhere = await run([folder.appendingPathComponent("no-such-folder-\(marker)/x.md").path])
        log.check(nowhere?.status == 1 && nowhere?.error.contains("its folder doesn't exist") == true, "a file in a folder that isn't there: \(nowhere?.error ?? "no answer")")
        let typo = folder.appendingPathComponent("typo-\(marker).md")
        let typed = await run([typo.path])
        let typoOpened = await waitFor(10) { Documents.existing(for: typo)?.ready == true && FileManager.default.fileExists(atPath: typo.path) }
        Documents.existing(for: typo)?.editor.textView.window?.performClose(nil)
        let left = await waitFor(15) { Documents.existing(for: typo) == nil && !FileManager.default.fileExists(atPath: typo.path) }
        let kept = FileManager.default.fileExists(atPath: History(root: NibPaths.support.appendingPathComponent("History"), path: typo.path).directory.path)
            || ClosedItems.shared.items.contains { $0.path == typo.path } || RecentFiles.shared.urls.contains(typo)
        AppDelegate.openListed(typo)
        try? await Task.sleep(for: .milliseconds(500))
        let notAgain = Documents.existing(for: typo) == nil && !FileManager.default.fileExists(atPath: typo.path)
        log.check(typed?.status == 0 && typoOpened && left && !kept && notAgain,
                  "rune on a path with no file: made empty to open (\(typoOpened)), gone when closed still empty (\(left)), nothing kept for it (\(!kept)), and not made again from a list (\(notAgain))")
        try? FileManager.default.removeItem(at: typo)
        let wrong = await run(["-x"])
        log.check(wrong?.status == 2 && wrong?.error.hasPrefix("rune: unknown option -x") == true && wrong?.error.contains("show this help") == true
                  && wrong?.error.contains("Exits 0 when done") == true,
                  "an unknown option: exit 2 and the usage, with --scratch and the exit statuses (the QA review's F73)")
        let both = await run(["-w", "-a"])
        log.check(both?.status == 2 && both?.error.contains("-w waits for files to close, and -a opens none") == true, "-w with -a: refused, not ignored (\(both?.error.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no answer"))")

        // A waiting -w let go when Nib quits, its file saved first.
        let quitWaiter = start(["-w", made[2].path])
        _ = await waitFor(10) { CLIBridge.waiters(for: made[2]) == 1 && Documents.existing(for: made[2])?.ready == true }
        CLIBridge.quitting()
        let letGo = await finish(quitWaiter, 10)
        log.check(letGo?.status == 0, "rune -w returns when Rune quits (exit \(letGo.map { "\($0.status)" } ?? "none"))")
        await close(made[2])
        log.check(Bridge.waiting().isEmpty, "no request left in the folder")
    }

    /// Files and tabs (ED2, ED4, §5.12): ⌘1…⌘9 picking a tab, but ⌘1-⌘3 left to the Conflicts
    /// menu with the caret in a block; Duplicate as an untitled copy; Rename… (the file, its
    /// History, caret and Recent entry carried over), refused onto another file, and by case
    /// alone; Move To… a folder, and refused outside the test folder; an untitled buffer
    /// renamed; the scratch file not moved; files dragged onto a window opened, folders not.
    static func fileOpsScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let fm = FileManager.default
        let folder = document.url.deletingLastPathComponent()
        let sub = folder.appendingPathComponent("sub-\(marker)", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let names = ["a", "b", "c", "d", "e"].map { "\($0)-\(marker).txt" }
        let urls = names.map { folder.appendingPathComponent($0) }
        for (n, url) in urls.enumerated() {
            let text = n == 3 ? "<<<<<<< A · 10:00\nours \(marker)\n=======\ntheirs\n>>>>>>> B · 10:00\n" : "file \(names[n])\nsecond line\n"
            try? Data(text.utf8).write(to: url)
        }
        var extra: [URL] = []   // made along the way
        defer {
            for open in Documents.all where open !== document { open.editor.textView.window?.performClose(nil) }
            for url in urls + extra {
                try? fm.removeItem(at: url)
                for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
                if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
                RecentFiles.shared.remove(url)
            }
            try? fm.removeItem(at: sub)
        }
        func opened(_ url: URL) async -> Document? {
            _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window != nil }
            return Documents.existing(for: url)
        }
        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        // Tabs: a, b, c and d (with a conflict block) in one window, the scratch file's (A5, 2026-10-02).
        for url in urls.prefix(4) { AppDelegate.openFile(url) }
        var docs: [Document] = []
        for url in urls.prefix(4) { if let open = await opened(url) { docs.append(open) } }
        _ = await waitFor(10) { docs.first?.editor.textView.window?.tabGroup?.windows.count == 5 }
        let windows = docs.compactMap(\.editor.textView.window)
        let group = windows.first?.tabGroup
        log.check(docs.count == 4 && group?.windows.count == 5 && group?.windows.contains { $0 === AppDelegate.scratchWindow } == true,
                  "four files and the scratch file, five tabs in one window (\(group?.windows.count ?? 0))")
        if docs.count == 4, let group {
            let two = AppDelegate.selectTab(2, in: windows[0])
            let second = group.selectedWindow === group.windows[1]
            let nine = AppDelegate.selectTab(9, in: windows[0])
            log.check(two && second && nine && group.selectedWindow === group.windows[1], "⌘2 picks the second tab; ⌘9 with five only beeps")
            // A file in a tab behind another isn't "in front": its problems are notified (F37).
            let behind = Documents.all.first { doc in doc.editor.textView.window.map { ($0.tabGroup?.selectedWindow ?? $0) !== $0 } ?? false }
            log.check(behind.map { !Notifier.inFront($0.url) } ?? false, "a file in a tab behind another counts as out of sight, for notifications (\(behind?.url.lastPathComponent ?? "none"))")
            // Each tab's text named for VoiceOver by its file: every editor was "Scratch" (F36).
            let labels = Documents.all.map { ($0.url.lastPathComponent, $0.editor.textView.accessibilityLabel() ?? "") }
            log.check(labels.allSatisfy { $0.0 == $0.1 }, "each file's text is named for VoiceOver by its file (\(labels.map(\.1).joined(separator: ", ")))")
            // The keys read as the keyboard has them: Caps Lock on, or AZERTY's "é" on the 2 key (the
            // QA review's F29: both turned ⌘K and ⌘1…⌘9 off).
            func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> AppDelegate.TabKey? {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code).flatMap(AppDelegate.tabKey)
            }
            log.check(press(19, "2", [.command, .capsLock]) == .tab(2) && press(19, "é", .command) == .tab(2) && press(40, "K", [.command, .capsLock]) == .goToFile
                      && press(19, "2", [.command, .shift]) == nil && press(19, "2", [.command, .option]) == nil,
                      "⌘2 and ⌘K with Caps Lock on, and ⌘2 on AZERTY, still pick the tab and Go to File; ⇧⌘2 and ⌥⌘2 don't")
            let d = docs[3]
            if let block = d.blocks.first { d.editor.textView.setSelectedRange(NSRange(location: block.range.location + 2, length: 0)) }
            let inBlock = d.activeCaretBlock != nil
            let one = AppDelegate.selectTab(1, in: windows[3]), four = AppDelegate.selectTab(4, in: windows[3])
            log.check(inBlock && !one && four, "with the caret in a conflict block ⌘1 is left to the Conflicts menu (Use the first version); ⌘4 still picks a tab")
            let first = AppDelegate.selectTab(1, in: AppDelegate.scratchWindow)
            log.check(first && group.selectedWindow === group.windows[0], "⌘1 from the scratch file picks the first tab: it's one of them now")
        }

        // Duplicate: an untitled copy with the same text.
        let before = Set(Documents.all.map(\.url))
        if let a = Documents.existing(for: urls[0]) { FileCommands.duplicate(a) }
        _ = await waitFor(10) { Documents.all.contains { !before.contains($0.url) && $0.untitled && $0.ready } }
        let copy = Documents.all.first { !before.contains($0.url) && $0.untitled }
        if let copy { extra.append(copy.url) }
        log.check(copy?.url.lastPathComponent == "a-\(marker) copy.txt" && copy?.editor.textView.string == "file \(names[0])\nsecond line\n",
                  "Duplicate: an untitled buffer “\(copy?.url.lastPathComponent ?? "none")” with the same text")

        // Rename…: the file and what Nib keeps for it go to the new name.
        let renamed = folder.appendingPathComponent("renamed-\(marker).txt")
        extra.append(renamed)
        if let b = Documents.existing(for: urls[1]) {
            b.editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
            b.editor.saveSelection(for: b.url)
            let history = History(root: NibPaths.support.appendingPathComponent("History"), path: urls[1].path).directory
            let hadHistory = fm.fileExists(atPath: history.path)
            let why = await FileCommands.rename(b, to: renamed.lastPathComponent)
            let now = await opened(renamed)
            let historyMoved = fm.fileExists(atPath: History(root: NibPaths.support.appendingPathComponent("History"), path: renamed.path).directory.path)
            log.check(why == nil && now != nil && !fm.fileExists(atPath: urls[1].path) && text(renamed) == "file \(names[1])\nsecond line\n"
                      && Documents.existing(for: urls[1]) == nil && now?.editor.textView.selectedRange().location == 7
                      && (!hadHistory || historyMoved) && RecentFiles.shared.urls.first?.path == renamed.path && !RecentFiles.shared.urls.contains { $0.path == urls[1].path },
                      "Rename…: the file under its new name, open, the caret where it was, its History (\(hadHistory ? "moved" : "none")) and Recent entry carried over\(why.map { " (\($0))" } ?? "")")
            if let now {
                let clash = await FileCommands.rename(now, to: names[2])
                log.check(clash?.contains("IS ALREADY THERE") == true && Documents.existing(for: renamed) === now && fm.fileExists(atPath: renamed.path),
                          "onto another file's name: refused (\(clash ?? "no answer")), nothing moved")
                // A failure: the ✕, in the red; a wait's notice dim; a problem's tag kept under a
                // notice (the QA review's F40: bright, no glyph, the problem hidden).
                let red = StatusStrip.color(notice: now.notice, state: now.state) == HUDColor.failureText
                let dim = StatusStrip.color(notice: "‖ WAITING", state: .synced(Date())) == HUDColor.dim
                log.check(now.notice?.hasPrefix("✕ “") == true && red && dim && SyncState.problem("DELETED").tag == "✕",
                          "a refusal on the strip is a failure: ✕, in the red (\(now.notice ?? "no notice"))")
                // An empty name, said as such; a name starting with "." (`.env`) allowed, then back
                // (the QA review's F70: refused as "can't be a file name", and "“”" for an empty one).
                let empty = await FileCommands.rename(now, to: "  ")
                let dotted = renamed.deletingLastPathComponent().appendingPathComponent(".dot-\(marker).txt")
                let dotWhy = await FileCommands.rename(now, to: dotted.lastPathComponent)
                let dotOpen = await waitFor(10) { Documents.existing(for: dotted)?.ready == true }
                if let back = Documents.existing(for: dotted) {
                    _ = await FileCommands.rename(back, to: renamed.lastPathComponent)
                    _ = await waitFor(10) { Documents.existing(for: renamed)?.ready == true }
                }
                log.check(empty == "✕ A NAME IS NEEDED · NOTHING RENAMED" && dotWhy == nil && dotOpen && Documents.existing(for: renamed) != nil,
                          "an empty name: “\(empty ?? "renamed")”; a name starting with “.”: renamed\(dotWhy.map { " not (\($0))" } ?? ""), and back")
            }
        }
        // By case alone: the same file to the disk, a new name to Nib.
        let upper = folder.appendingPathComponent("C-\(marker).txt")
        if let c = Documents.existing(for: urls[2]) {
            let why = await FileCommands.rename(c, to: upper.lastPathComponent)
            _ = await opened(upper)
            let listed = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            log.check(why == nil && listed.contains(upper.lastPathComponent) && !listed.contains(names[2]) && Documents.existing(for: upper)?.ready == true,
                      "Rename… by case alone (c- to C-): done, as Finder would\(why.map { " (\($0))" } ?? "")")
            extra.append(upper)
        }

        // Move To…: another folder, and not out of the test folders.
        let moved = sub.appendingPathComponent(names[0])
        extra.append(moved)
        if let a = Documents.existing(for: urls[0]) {
            let outside = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/\(names[0])")   // a path only: nothing is written there
            let refused = await FileCommands.move(a, to: outside)
            log.check(refused?.hasPrefix("✕ NOT MOVED · RUNE OPENS ONLY TEST FILES") == true && Documents.existing(for: urls[0]) === a && !fm.fileExists(atPath: outside.path),
                      "Move To… outside the test folder: refused (\(refused ?? "no answer"))")
            let why = await FileCommands.move(a, to: moved)
            _ = await opened(moved)
            log.check(why == nil && fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: urls[0].path) && Documents.existing(for: moved)?.ready == true,
                      "Move To… a folder: the file there, open, and gone from here\(why.map { " (\($0))" } ?? "")")
        }

        // An untitled buffer renamed; the scratch file never.
        if let copy {
            let name = "notes-\(marker).md"
            let root = NibPaths.support.appendingPathComponent("History")
            let why = await FileCommands.rename(copy, to: name)
            _ = await waitFor(10) { Documents.all.contains { $0.untitled && $0.url.lastPathComponent == name && $0.ready } }
            let again = Documents.all.first { $0.untitled && $0.url.lastPathComponent == name }
            _ = await waitFor(10) { Documents.existing(for: copy.url) == nil }
            if let again { extra.append(again.url) }
            // Its History went with it (guarantee 2): left at the old path, nothing reached it again (§8, 2026-10-03).
            let carried = again?.history.entries().contains { $0.sha256 == Digest.sha256(Data("file \(names[0])\nsecond line\n".utf8)) } == true
            log.check(why == nil && again?.editor.textView.string == "file \(names[0])\nsecond line\n" && !fm.fileExists(atPath: copy.url.path)
                      && !ClosedItems.shared.items.contains { $0.path == copy.url.path }
                      && carried && !fm.fileExists(atPath: History(root: root, path: copy.url.path).directory.path),
                      "an untitled buffer renamed: “\(again?.url.lastPathComponent ?? "none")”, its History with it, the old one gone, nothing left to reopen")
        }
        let scratch = await FileCommands.rename(document, to: "elsewhere-\(marker).md")
        log.check(!FileCommands.canMove(document) && scratch?.hasPrefix("✕ THE SCRATCH FILE STAYS") == true && Documents.scratch.url == document.url,
                  "the scratch file isn't renamed or moved: \(scratch ?? "no answer")")

        // Files dragged onto a window: files open, folders don't.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nib-scenario-\(marker)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([urls[4] as NSURL, sub as NSURL])
        let dropped = NibTextView.files(on: pasteboard)
        NibTextView.openFiles(dropped)
        let droppedOpen = await opened(urls[4])
        pasteboard.releaseGlobally()
        log.check(dropped == [urls[4]] && droppedOpen != nil, "a file dragged onto a window opens (\(dropped.map(\.lastPathComponent).joined(separator: ", "))); a folder with it doesn't")

        // The File menu.
        let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
        if let file { PaletteSession.refresh(file) }
        let duplicateKeys = file?.items.first { $0.title == "Duplicate" }.flatMap(PaletteSession.keys(of:))
        log.check(duplicateKeys == "⇧⌘S" && file?.items.contains { $0.title == "Rename…" } == true && file?.items.contains { $0.title == "Move To…" } == true,
                  "File › Duplicate \(duplicateKeys ?? "none"), Rename…, Move To…")
    }

    /// Delivery receipts (SY14, §4.5), with a hand-written receipt standing in for another Mac:
    /// this Mac's receipt for the scratch file written (the version its buffer comes from), at
    /// most every 5 s; another Mac with this very version ("✓ SYNCED · ON TEST MAC"), the card,
    /// VoiceOver's words and the Sync Log's time; one with a version this Mac hasn't seen
    /// ("▼ NEWER ON TEST MAC · NOT HERE YET"); one with an earlier version (nothing on the strip,
    /// a line on the card); and a receipt of a later format, ignored.
    static func receiptsScenario(_ log: HarnessLog, _ marker: String) async {
        // A file of its own: the real other Macs' receipts name the scratch file, and one left by
        // a two-Mac run took the strip from the stand-in (the suite, 2026-09-30).
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("receipts-\(marker).md")
        try? Data("# Receipts \(marker)\n".utf8).write(to: url)
        defer {
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(url)
        }
        AppDelegate.openFile(url)
        _ = await waitFor(30) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.held == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "its own test file opened and held"); return }
        await waitSynced(document, 30)
        let folder = DeviceReceipts.folder(for: document.url)
        let mine = DeviceReceipts.url(in: folder, device: document.device)
        let other = DeviceReceipts.url(in: folder, device: "Test Mac")
        let name = document.url.lastPathComponent
        func disk() -> String { Digest.sha256((try? Data(contentsOf: document.url)) ?? Data()) }
        func pretend(_ sha: String, format: Int = DeviceReceipts.currentFormat) {
            var receipts = DeviceReceipts(device: "Test Mac", files: [name: .init(sha256: sha, time: Date())])
            receipts.format = format
            try? receipts.write(to: other)
            // Hidden, as iCloud marks the files in `.nib` (the two-Mac test at 17:50 read none).
            var hidden = URLResourceValues()
            hidden.isHidden = true
            var url = other
            try? url.setResourceValues(hidden)
        }
        /// The stand-in's line; the real other Macs' receipts may be in the folder too.
        func testMac() -> Document.OtherMac? { document.otherMacs.first { $0.device == "Test Mac" } }
        defer { try? FileManager.default.removeItem(at: other) }
        let before = disk()

        // This Mac's receipt: the version its buffer comes from, written at most every 5 s.
        let writes = ReceiptBook.shared.written
        await type("\n- receipt one \(marker)\n", into: document)
        await document.flush(reason: "test")
        try? await Task.sleep(for: .milliseconds(1_500))
        await type("- receipt two \(marker)\n", into: document)
        await document.flush(reason: "test")
        await waitSynced(document, 30)
        let current = disk()
        let published = await waitFor(12) { DeviceReceipts.read(mine)?.files[name]?.sha256 == current }
        log.check(published && ReceiptBook.shared.written - writes <= 3,
                  "this Mac's receipt says the version its buffer comes from (\(String(current.prefix(8)))), in \(ReceiptBook.shared.written - writes) writes for two saves 1.5 s apart")

        // Another Mac with this very version.
        pretend(current)
        let same = await waitFor(10) { document.statusLine.hasPrefix("✓ SYNCED · ON TEST MAC ") }
        log.line("receipts read: \(document.otherMacs.map { "\($0.device) (\($0.delivery), \(String($0.loaded.sha256.prefix(8))))" }.joined(separator: ", "))")
        let card = MenuBarState.card(document)
        log.check(same && card.contains { $0.hasPrefix("✓ ON TEST MAC · SINCE ") } && document.statusSpoken.contains(", and on Test Mac since "),
                  "another Mac with this version: “\(document.statusLine)”, on the card too, and said “\(document.statusSpoken)”")
        _ = await waitFor(3) { SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().last { $0.event == "receipt" }?.sha256 == current }
        let logged = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().last { $0.event == "receipt" && $0.sha256 == current }
        log.check(logged?.detail?.hasPrefix("Test Mac has this version, ") == true, "the Sync Log says how long it took: \(logged?.detail ?? "nothing")")

        // One this Mac hasn't seen, and changed in place, as iCloud changes a receipt that's
        // there already: the folder stays as it was, so only the presenter can tell. Anything else
        // writing in the folder meanwhile (iCloud settling the receipt just written, this Mac's
        // own) leaves that unproven, so then once more, with another version (the suite at 22:26,
        // 2026-10-06, the strip right and the folder changed).
        func folderChanged() -> Date? { (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        var newer = false, onCard = false, folderKept = false, tries = 0
        repeat {
            tries += 1
            let unseen = Digest.sha256(Data("a version only Test Mac has \(marker) \(tries)".utf8))
            let folderBefore = folderChanged()
            if let data = try? DeviceReceipts(device: "Test Mac", files: [name: .init(sha256: unseen, time: Date())]).encoded() {
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: other, options: [], error: &error) { url in
                    guard let handle = try? FileHandle(forWritingTo: url) else { return }
                    try? handle.truncate(atOffset: 0)
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                }
            }
            newer = await waitFor(10) {
                testMac()?.loaded.sha256 == unseen && document.statusLine.hasPrefix("▼ NEWER ON TEST MAC · ") && document.statusLine.hasSuffix(" · NOT HERE YET")
            }
            onCard = MenuBarState.card(document).contains { $0.hasPrefix("▼ NEWER ON TEST MAC · ") }
            folderKept = folderChanged() == folderBefore
        } while newer && !folderKept && tries < 2
        log.check(newer && onCard && folderKept,
                  "another Mac with a version this Mac hasn't seen, its receipt changed in place: “\(document.statusLine)”, on the card \(onCard), the folder unchanged \(folderKept)\(tries > 1 ? " (on the second try: the folder changed under the first)" : "")")
        // Said the same way on the strip, the card and the HUD (the QA review's F41: "OLDER", "HAS
        // …'S", "(10:42)", and the HUD's STATE "✓ SYNCED" beside the strip's "▼ NEWER").
        if let other = testMac() {
            log.check(MenuBarState.card(document).contains(document.statusLine) && other.short == "▼ NEWER · \(other.time)"
                      && SyncHUD.stateWord(document) == "▼ NEWER ON TEST MAC" && other.sentence.hasPrefix("Test Mac has a newer version, from "),
                      "one wording: the strip's line on the card, the HUD's “\(other.short)” and STATE “\(SyncHUD.stateWord(document))”")
        }

        // An earlier one: the strip as it was, a line on the card.
        pretend(before)
        let earlier = await waitFor(10) { testMac()?.delivery == .earlier }
        log.check(earlier && !document.statusLine.contains("TEST MAC") && MenuBarState.card(document).contains { $0.hasPrefix("TEST MAC HASN'T GOT THIS VERSION YET") },
                  "another Mac with an earlier version: the strip says only “\(document.statusLine)”; the card, that Test Mac hasn't got it yet")

        // A later format: ignored, not misread.
        pretend(current, format: DeviceReceipts.currentFormat + 1)
        let ignored = await waitFor(10) { testMac() == nil }
        log.check(ignored && !document.statusLine.contains("TEST MAC"), "a receipt of a later format is ignored")

        // This Mac renamed: its file under the former name (nothing in it later than the rename)
        // isn't read as another Mac's, and the next write carries it over to this name and
        // removes it; a file under a name another Mac took since (an entry after the rename) is
        // that Mac's, left alone.
        let sibling = url.deletingLastPathComponent().appendingPathComponent("receipts-sibling-\(marker).md")
        let formerName = "Former Test Mac", takenName = "Taken Test Mac"
        let formerURL = DeviceReceipts.url(in: folder, device: formerName)
        let takenURL = DeviceReceipts.url(in: folder, device: takenName)
        defer {
            for file in [sibling, formerURL, takenURL] { try? FileManager.default.removeItem(at: file) }
            for who in [formerName, takenName] { ReceiptBook.shared.forgetRenamed(who) }
        }
        try? Data("# Sibling \(marker)\n".utf8).write(to: sibling)
        let renamedAt = Date()
        for who in [formerName, takenName] { ReceiptBook.shared.pretendRenamed(from: who, at: renamedAt) }
        let siblingSHA = Digest.sha256(Data("the sibling as this Mac had it \(marker)".utf8))
        try? DeviceReceipts(device: formerName, files: [
            name: .init(sha256: current, time: renamedAt.addingTimeInterval(-60)),
            sibling.lastPathComponent: .init(sha256: siblingSHA, time: renamedAt.addingTimeInterval(-60)),
        ]).write(to: formerURL)
        try? DeviceReceipts(device: takenName, files: [name: .init(sha256: current, time: renamedAt.addingTimeInterval(30))]).write(to: takenURL)
        let heard = await waitFor(10) { document.otherMacs.contains { $0.device == takenName } }
        log.check(heard && !document.otherMacs.contains { $0.device == formerName },
                  "this Mac's receipt under a former name isn't read as another Mac's; one under a name taken since is (\(document.otherMacs.map(\.device).joined(separator: ", ")))")
        await type("- receipt three \(marker)\n", into: document)
        await document.flush(reason: "test")
        await waitSynced(document, 30)
        let third = disk()
        let carried = await waitFor(12) {
            !FileManager.default.fileExists(atPath: formerURL.path) && DeviceReceipts.read(mine)?.files[name]?.sha256 == third
        }
        let entries = DeviceReceipts.read(mine)?.files ?? [:]
        log.check(carried && entries[sibling.lastPathComponent]?.sha256 == siblingSHA && FileManager.default.fileExists(atPath: takenURL.path),
                  "the next write carries the former name's entries over (the sibling's \(entries[sibling.lastPathComponent].map { String($0.sha256.prefix(8)) } ?? "missing")) and removes its file; the taken name's stays")
    }

    /// About's Acknowledgements opened as About opens (the `about` scenario: its button can't
    /// be clicked from here).
    static var openAcknowledgements = false

    /// About Nib (§5.10) and its Acknowledgements (DS3): the window from the app menu, the version,
    /// and every notice Nib ships. Pictures: build/scenarios/about.png and acknowledgements.png.
    static func aboutScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()
        func window(_ id: String) -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains(id) == true } }
        func picture(_ window: NSWindow?, _ name: String) {
            guard let view = window?.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
        }
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let index = appMenu?.items.firstIndex { $0.title == "About Rune" }
        openAcknowledgements = true
        defer { openAcknowledgements = false }
        if let appMenu, let index { appMenu.performActionForItem(at: index) }
        let about = await waitFor(5) { window("about") != nil }
        let acknowledgements = await waitFor(5) { window("acknowledgements") != nil }
        try? await Task.sleep(for: .milliseconds(500))
        let width = window("about")?.frame.width ?? 0
        picture(window("about"), "about.png")
        picture(window("acknowledgements"), "acknowledgements.png")
        log.check(index != nil && about && abs(width - 360) < 2 && AboutView.version.hasPrefix("V") && AboutView.version.contains(" · BUILD "),
                  "Rune › About Rune: Blit's About, \(Int(width)) points wide, \(AboutView.version)")
        let items = Acknowledgements.load()
        let names = items.map(\.title)
        let wanted = ["SwiftTreeSitter", "tree-sitter 0.", "tree-sitter-gitcommit", "tree-sitter-ini", "An Old Hope", "Silkscreen (font)", "VT323 (font)"]
        let missing = wanted.filter { want in !names.contains { $0.hasPrefix(want) } }
        let gitcommit = items.first { $0.title.hasPrefix("tree-sitter-gitcommit") }
        log.check(acknowledgements && items.count >= 30 && missing.isEmpty && items.allSatisfy { !$0.text.isEmpty } && gitcommit?.details.contains("License: WTFPL") == true,
                  "its Acknowledgements: \(items.count) notices, each with its license text\(missing.isEmpty ? "" : " (missing: \(missing.joined(separator: ", ")))")")
        window("acknowledgements")?.close()
        window("about")?.close()
    }

    /// The Dock (AP8, AP6): the ✕ badge on Nib's icon while a file has conflict blocks, gone once
    /// they're resolved; and the icon hidden by Settings › General only while the nib in the menu
    /// bar is on. Picture: build/scenarios/dock-badge.png.
    static func dockScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()
        let block = "<<<<<<< This Mac · 10:42\nmine\n=======\ntheirs\n>>>>>>> Test Mac · 10:43\n"
        guard let url = Untitled.create(text: "# Dock \(marker)\n\n" + block, name: "dock-\(marker).md") else { log.check(false, "a buffer with a conflict block"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let buffer = Documents.existing(for: url) else {
            log.check(false, "it opened")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())   // or it comes back at the next launch
            return
        }
        let shown = await waitFor(5) { DockBadge.shared.showing && NSApp.dockTile.contentView != nil }
        try? DockBadge.shared.picture()?.write(to: folder.appendingPathComponent("dock-badge.png"))
        // The ✕'s words, in the Dock's menu: the tile has none for VoiceOver (the QA review's F82).
        // (Asked as the Dock asks it: of SwiftUI's delegate, which hands it on to Nib's.)
        let delegate = NSApp.delegate
        let menu = delegate?.applicationDockMenu?(NSApp)
        let line = menu?.items.first
        log.check(menu?.items.count == 1 && line?.title == "Conflict in “\(url.lastPathComponent)”, 1 place"
                  && (line?.representedObject as? URL) == url && line?.action == #selector(AppDelegate.openFromDock(_:)),
                  "and the Dock's menu says it: “\(line?.title ?? "nothing")”, opening the file")
        // Resolved by hand: the markers taken out, both sides kept.
        let view = buffer.editor.textView
        view.insertText("# Dock \(marker)\n\nmine\ntheirs\n", replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
        let gone = await waitFor(5) { !DockBadge.shared.showing && NSApp.dockTile.contentView == nil }
        log.check(shown && gone && buffer.blocks.isEmpty && delegate?.applicationDockMenu?(NSApp)?.items.contains(where: { $0.title.hasPrefix("Conflict in") }) != true,
                  "a conflict block puts the ✕ on Rune's icon in the Dock, and it goes once the block is resolved, with its line in the Dock's menu")
        Untitled.letGo(url)
        view.window?.performClose(nil)
        if !(await waitFor(15) { !FileManager.default.fileExists(atPath: url.path) }) { log.line("the buffer was still there after 15 s") }

        // Settings › General: Show Nib in the Dock off, with and without the nib in the menu bar.
        let defaults = NibDefaults.store
        defer {
            defaults.removeObject(forKey: "hideDockIcon")
            defaults.removeObject(forKey: "showMenuBarExtra")
        }
        defaults.set(false, forKey: "showMenuBarExtra")
        defaults.set(true, forKey: "hideDockIcon")
        try? await Task.sleep(for: .milliseconds(500))
        let kept = NSApp.activationPolicy() == .regular
        defaults.set(true, forKey: "showMenuBarExtra")
        let hidden = await waitFor(3) { NSApp.activationPolicy() == .accessory }
        defaults.set(false, forKey: "hideDockIcon")
        let back = await waitFor(3) { NSApp.activationPolicy() == .regular }
        defaults.set(false, forKey: "showMenuBarExtra")
        log.check(kept && hidden && back,
                  "Show Rune in the Dock off: kept while Rune in the menu bar is off (\(kept)), hidden with it on (\(hidden)), back when on again (\(back))")
    }

    /// Services and Shortcuts (SC8, PT7): Append to Nib Scratch and Clean Text as the system sends
    /// them (on a pasteboard of their own), and the three App Intents as Shortcuts runs them.
    /// The trial's lock (DS4), with `-NibLicensing YES` and the trial and license in memory: day 1
    /// types; the trial over, typing goes on until a minute without it; then read-only (typing,
    /// paste, Append to Scratch, ⌘N, Clean Clipboard, `rune -w` and `cmd | rune -a` refused, each
    /// saying why), while another app's version still comes in and a conflict still resolves; a
    /// license lifts it; a month unchecked offline brings it back.
    static func licenseScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let license = LicenseManager.shared
        guard license.isEnforced, license.storage is MemoryLicenseStorage else {
            log.check(false, "licensing on and in memory (-NibLicensing YES in a test run)")
            return
        }
        let view = document.editor.textView
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()
        defer { license.testSet(trialStartedDaysAgo: 0, license: .some(nil)) }

        license.testSet(trialStartedDaysAgo: 0, license: .some(nil))
        await type("\n- day one \(marker)\n", into: document)
        log.check(license.state == .trial(daysLeft: 7) && !license.typingLocked && view.string.contains("day one \(marker)"),
                  "day 1: \(license.summary), typing goes in")

        // A block typed while it's allowed, to resolve once it isn't.
        let block = "<<<<<<< Scenario A · 10:00\n- ours \(marker)\n=======\n- theirs \(marker)\n>>>>>>> Scenario B · 10:00\n"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(block, replacementRange: view.selectedRange())
        await endOfEvent(view)

        // The eighth day, typed a moment ago: never mid-sentence.
        license.testSet(trialStartedDaysAgo: 8)
        await type("- still typing \(marker)\n", into: document)
        log.check(license.state == .trialEnded && !license.typingLocked && view.isEditable && view.string.contains("still typing \(marker)"),
                  "day 8, typing a moment ago: not locked yet, typing goes on (\(license.summary))")

        await document.flush(reason: "test")
        await waitSynced(document, 30)
        license.testSet(quietFor: 61)
        log.check(license.typingLocked && !view.isEditable, "a minute without typing: read-only (\(license.stripLine))")
        if let window = view.window, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("license.png"))
        }

        let before = view.string
        view.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
        view.insertText("typed while locked \(marker)", replacementRange: view.selectedRange())
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("pasted\u{200B} while locked \(marker)", forType: .string)
        view.paste(nil)
        await endOfEvent(view)
        log.check(view.string == before, "typing and ⌘V change nothing")
        let appended = Clipboard.append("appended while locked \(marker)", action: "Append", from: "THE TEST")
        let cleaned = Clipboard.cleanInPlace()
        let clipboard = pasteboard.string(forType: .string) ?? ""
        restorePasteboard(saved)
        let files = Documents.all.count
        AppDelegate.newUntitled()
        try? await Task.sleep(for: .milliseconds(500))
        log.check(view.string == before && appended == .locked(license.refusedHUD) && cleaned.hasPrefix("✕ RUNE IS READ-ONLY")
                    && clipboard.contains("\u{200B}") && Documents.all.count == files,
                  "Append to Scratch, Clean Clipboard and ⌘N refused, saying why (“\(appended.hud)”, “\(cleaned)”)")

        // The rune command (when the runner names it): -w exits at once, and so does -a.
        if let tool = NibDefaults.store.string(forKey: "NibCLI"), FileManager.default.isExecutableFile(atPath: tool) {
            func run(_ arguments: [String], input: String? = nil) async -> (status: Int32, error: String)? {
                let process = Process(), stdin = Pipe(), stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.environment = ["NIB_SCENARIOS": "1", "NIB_NO_LAUNCH": "1", "NIB_NO_ACTIVATE": "1", "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
                process.standardInput = stdin
                process.standardOutput = Pipe()
                process.standardError = stderr
                try? process.run()
                if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
                try? stdin.fileHandleForWriting.close()
                guard await waitFor(15, { !process.isRunning }) else { process.terminate(); return nil }
                let said = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return (process.terminationStatus, said.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let waited = await run(["-w", document.url.deletingLastPathComponent().appendingPathComponent("license-\(marker).txt").path])
            let appendedByTool = await run(["-a"], input: "piped while locked \(marker)\n")
            log.check(waited?.status == 1 && waited?.error.contains("trial has ended") == true && appendedByTool?.status == 1 && view.string == before,
                      "rune -w and cmd | rune -a exit 1 at once (“\(waited?.error ?? "no answer")”)")
            try? FileManager.default.removeItem(at: document.url.deletingLastPathComponent().appendingPathComponent("license-\(marker).txt"))
        }

        // Never locked: another app's version comes in, and the block resolves.
        append("from another app while locked \(marker)", to: document.url)
        let reloaded = await waitFor(10) { view.string.contains("from another app while locked \(marker)") }
        log.check(reloaded && !view.isEditable, "another app's version comes in, still read-only (\(document.notice ?? document.state.line))")
        let resolved = await keepBoth(document, marker)
        log.check(resolved && view.string.contains("- ours \(marker)\n- theirs \(marker)") && !view.isEditable,
                  "⌘3 resolves the conflict, into the file, still read-only")

        // A license lifts it; a month unchecked offline brings it back.
        license.testSet(license: StoredLicense(key: "TEST-0000-\(marker)", instanceID: "i", email: "buyer@example.com", name: nil, lastValidated: Date()))
        await type("- licensed \(marker)\n", into: document)
        log.check(!license.typingLocked && view.isEditable && view.string.contains("licensed \(marker)"), "licensed: typing goes in (\(license.summary))")
        // The app menu: License… once licensed, Buy and Enter License before. (SwiftUI brings a
        // menu up to date as it opens: refreshed here as opening it would, as `files` does File.)
        func appMenu() -> [String] {
            guard let menu = NSApp.mainMenu?.items.first?.submenu else { return [] }
            PaletteSession.refresh(menu)
            return menu.items.map(\.title).filter { $0.contains("Buy") || $0.contains("License") }
        }
        let licensedMenu = await waitFor(3) { appMenu() == ["License…"] }
        log.check(licensedMenu, "licensed: the Rune menu has License…, not Buy Rune… or Enter License… (\(appMenu()))")
        license.testSet(license: StoredLicense(key: "TEST-0000-\(marker)", instanceID: "i", email: nil, name: nil, lastValidated: Date().addingTimeInterval(-36 * 86_400)))
        let graced = !license.typingLocked
        license.testSet(license: StoredLicense(key: "TEST-0000-\(marker)", instanceID: "i", email: nil, name: nil, lastValidated: Date().addingTimeInterval(-38 * 86_400)), quietFor: 61)
        log.check(graced && license.typingLocked && !view.isEditable, "unchecked 36 days: still licensed; 38 days: read-only (\(license.summary))")
        license.testSet(trialStartedDaysAgo: 0, license: .some(nil))
        log.check(!license.typingLocked && view.isEditable, "the trial back (day 1), as the test leaves it")
        let trialMenu = await waitFor(3) { appMenu() == ["Buy Rune…", "Enter License…"] }
        log.check(trialMenu, "in the trial: Buy Rune… and Enter License… again (\(appMenu()))")

        // With a real key (`-NibLicenseTestKey`, a test-mode purchase): Lemon Squeezy's own answers.
        // Activate, the weekly check, Deactivate (the activation freed again); and a made-up key.
        if let key = NibDefaults.store.string(forKey: "NibLicenseTestKey"), !key.isEmpty {
            let madeUp = await license.activate("RUNE-TEST-0000-0000-NOT-A-REAL-KEY", instanceName: "Rune test")
            log.check(madeUp?.hasPrefix("That license key wasn't found") == true && license.license == nil,
                      "a made-up key: “\(madeUp ?? "activated?!")”")
            let problem = await license.activate(key, instanceName: "Rune test")
            log.check(problem == nil && license.license != nil && !license.typingLocked, "a real key activates: \(problem ?? license.summary)")
            if var stored = license.license {
                stored.lastValidated = Date().addingTimeInterval(-8 * 86_400)
                license.testSet(license: stored)
                await license.revalidateIfDue()
                let checked = license.license.map { Date().timeIntervalSince($0.lastValidated) < 60 } ?? false
                log.check(checked && license.state == .licensed(email: license.license?.email), "the weekly check: still valid, checked now (\(license.summary))")
            }
            let freed = await license.deactivate()
            log.check(freed == nil && license.license == nil, "Deactivate This Mac frees the activation: \(freed ?? license.summary)")
        }
        // A key refunded or disabled after it was activated (`-NibLicenseRevokedKey`): the weekly
        // check hears it from Lemon Squeezy, the license goes, and Rune is read-only after a quiet minute.
        if let revoked = NibDefaults.store.string(forKey: "NibLicenseRevokedKey"), !revoked.isEmpty {
            license.testSet(license: StoredLicense(key: revoked, instanceID: "rune-test", email: nil, name: nil, lastValidated: Date().addingTimeInterval(-8 * 86_400)))
            let before = license.state
            await license.revalidateIfDue()
            license.testSet(quietFor: 61)
            var said = ""
            if case .revoked(let why) = license.state { said = why }
            log.check(before == .licensed(email: nil) && !said.isEmpty && license.license == nil && license.typingLocked && !view.isEditable,
                      "a key disabled since it was activated: the weekly check revokes it, read-only after a quiet minute (“\(said)”)")
            license.testSet(trialStartedDaysAgo: 0, license: .some(nil))
        }
        await document.flush(reason: "test")
    }

    static func servicesScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let view = document.editor.textView
        let board = NSPasteboard(name: NSPasteboard.Name("nib-services-\(marker)"))
        defer { board.releaseGlobally() }
        var error: NSString?

        board.clearContents()
        board.setString("appended by the service \(marker)\u{200B}   \n", forType: .string)
        ServiceProvider.shared.appendToScratch(board, userData: nil, error: &error)
        // Confirmed where it can be seen, with the scratch window behind (the QA review's F63).
        let confirmed = NSApp.isActive && AppDelegate.scratchWindow?.isKeyWindow == true || Announce.said.last == "Appended 1 line to scratch"
        log.check(confirmed, "Services › Append to Rune Scratch says what it did, with Rune behind (“\(Announce.said.last ?? "nothing")”)")
        log.check(error == nil && view.string.hasSuffix("\n\nappended by the service \(marker)\n"),
                  "Services › Append to Rune Scratch: the selection at the end of the scratch file after a blank line, cleaned (\((view.string.components(separatedBy: "\n").suffix(2).first ?? "").debugDescription))")

        let dirty = "  Text\u{00A0}with a no-break space\u{200B} and a zero-width one  \nsecond line   \n"
        board.clearContents()
        board.setString(dirty, forType: .string)
        ServiceProvider.shared.cleanText(board, userData: nil, error: &error)
        let cleaned = board.string(forType: .string) ?? ""
        log.check(error == nil && cleaned == CleanTextIntent.clean(dirty) && !cleaned.contains("\u{00A0}") && !cleaned.contains("\u{200B}") && !cleaned.contains("   \n"),
                  "Services › Clean Text: the selection back as clean plain text (\(cleaned.debugDescription))")

        let append = AppendToScratchIntent()
        append.text = "appended by Shortcuts \(marker)"
        let ran = (try? await append.perform()) != nil
        let got = try? await GetScratchIntent.text()
        log.check(ran && view.string.hasSuffix("\n\nappended by Shortcuts \(marker)\n") && got == view.string,
                  "Shortcuts: Append to Scratch adds to its end, and Get Scratch gives its text as it is in Rune (\(got.map { "\(($0 as NSString).length) characters" } ?? "nothing"))")
        log.check(CleanTextIntent.clean("a\u{200B}b   \n") == "ab\n", "Shortcuts: Clean Text (\(CleanTextIntent.clean("a\u{200B}b   \n").debugDescription))")

        // Nothing left once cleaned: said of where the text came from (the QA review's F19: "the
        // clipboard has no text" for the selection, a Shortcut's text and `nib -a` too).
        let before = view.string
        board.clearContents()
        board.setString("\u{200B}   \n", forType: .string)
        error = nil
        ServiceProvider.shared.appendToScratch(board, userData: nil, error: &error)
        let shortcut = AppendToScratchIntent()
        shortcut.text = "\u{200B}\n"
        var thrown = ""
        do { _ = try await shortcut.perform() } catch { thrown = "\(error)" }
        let service = (error as String?) ?? ""
        log.check(view.string == before && service.contains("selection is empty once cleaned") && thrown.contains("text is empty once cleaned"),
                  "nothing to append, said of where it came from: “\(service)”, “\(thrown)”")
    }

    /// The sync HUD (§5.3, SY16): View › Show Sync Details (⇧⌘Y) opens it over the text's foot,
    /// Escape closes it, and the menu does both; its log is the file's last Sync Log lines in its
    /// words; a conflict block in the text adds the WARNING panel, and Escape takes the HUD before
    /// the banner. Pictures: build/scenarios/synchud.png and synchud-warning.png.
    static func syncHUDScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 30)
        let folder = URL(fileURLWithPath: log.path).deletingLastPathComponent()
        ScenarioFocus.take()
        document.editor.textView.window?.makeKeyAndOrderFront(nil)
        _ = await waitFor(5) { document.editor.textView.window?.isKeyWindow == true }

        // A save and an upload, for its log.
        await type("\n- sync hud \(marker)\n", into: document)
        await document.flush(reason: "test")
        await waitSynced(document, 30)
        let recent = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).recent(path: document.url.path, limit: SyncHUD.logLines)
        let lines = recent.map(SyncHUD.line)
        log.check(recent.count == SyncHUD.logLines && recent.allSatisfy { $0.path == document.url.path }
                  && lines.contains { $0.hasPrefix("= SAVED · ") } && lines.contains { $0.hasPrefix("▲ UPLOADED · ") },
                  "its log: the file's last \(recent.count) Sync Log lines, newest last, in its words (\(lines.suffix(3).joined(separator: " | ")))")
        // A detail's paths as names, and its semicolons and colons as dots (the QA review's F67).
        let detail = SyncHUD.hudDetail("to the Recovery folder (iCloud Drive is off): /Users/someone/Library/Application Support/nib/Recovery/notes.md; retrying")
        log.check(detail == "TO THE RECOVERY FOLDER (ICLOUD DRIVE IS OFF) · NOTES.MD · RETRYING", "a log line's detail in the HUD's grammar: \(detail)")
        // WARNING with two blocks says where the first is, not as if both were there (F68).
        let two = SyncHUD.whereWords(.init(count: 2, lines: 3...7)), one = SyncHUD.whereWords(.init(count: 1, lines: 3...3))
        log.check(two == "FIRST AT LINES 3-7" && one == "LINE 3", "the WARNING panel's lines: “\(two)”, “\(one)”")

        // A check for anything newer that finds nothing leaves the time alone (the QA review's F7:
        // "✓ SYNCED · 10:42:07" moved on every 30 s and at every focus).
        func syncedAt() -> Date? { if case .synced(let time) = document.state { time } else { nil } }
        let syncedBefore = syncedAt()
        try? await Task.sleep(for: .milliseconds(1_200))
        await document.fetchLatest(reason: "test")
        await document.fetchLatest(reason: "test")
        log.check(syncedBefore != nil && syncedAt() == syncedBefore, "checking again for a newer version leaves “\(document.statusLine)” as it was")
        // The pixel glyphs in Nib's words, not Blit's transfer words (the QA review's F39).
        let words = PixelGlyph.allCases.map(\.spoken)
        log.check(!words.contains("done") && !words.contains("transferring") && !words.contains("down"), "the glyphs' words, said alone: \(words.joined(separator: ", "))")

        func menuItem(_ title: String) -> (menu: NSMenu, index: Int)? {
            for top in NSApp.mainMenu?.items ?? [] {
                if let menu = top.submenu, let index = menu.items.firstIndex(where: { $0.title == title }) { return (menu, index) }
            }
            return nil
        }
        func choose(_ title: String) -> Bool {
            guard let (menu, index) = menuItem(title) else { return false }
            menu.update()
            menu.performActionForItem(at: index)
            return true
        }
        /// The window as drawn, saved as `name`.
        func picture(_ view: NSView, _ name: String) -> NSBitmapImageRep? {
            guard let frame = view.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return nil }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            if !name.isEmpty { try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name)) }
            return rep
        }
        /// The share of the band 40-200 points above the window's foot (over the strip, where
        /// the HUD opens) in a color.
        func share(_ rep: NSBitmapImageRep?, _ view: NSView, _ matches: (NSColor) -> Bool) -> Double {
            guard let rep, let width = view.window?.contentView?.superview?.bounds.width, width > 0 else { return 0 }
            let scale = Double(rep.pixelsWide) / width, height = rep.pixelsHigh
            var hits = 0, total = 0
            for y in stride(from: height - Int(200 * scale), to: height - Int(40 * scale), by: 7) {
                for x in stride(from: Int(40 * scale), to: rep.pixelsWide - Int(40 * scale), by: 11) {
                    total += 1
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matches(color) { hits += 1 }
                }
            }
            return total == 0 ? 0 : Double(hits) / Double(total)
        }
        func hudBlack(_ c: NSColor) -> Bool { c.redComponent < 0.06 && c.greenComponent < 0.06 && c.blueComponent < 0.06 }
        // The picture lightens colors (#B35C5C comes out #B77571, as `find`'s #FFE792 does #FCEBAD):
        // clearly red, where the text's own reds (a conflict block's tint) are dark.
        func failureRed(_ c: NSColor) -> Bool {
            c.redComponent > 0.6 && c.redComponent - c.greenComponent > 0.15 && c.redComponent - c.blueComponent > 0.15
        }
        let view = document.editor.textView
        let before = share(picture(view, ""), view, hudBlack)

        // View › Show Sync Details, on ⇧⌘Y. The menu acts on the document in front, which a
        // test run's Nib isn't while macOS keeps another app in front (the user at the Mac):
        // then the item is off, and the scenario takes its action, as `find` does ⌘F's.
        let item = menuItem("Show Sync Details")
        let keys = item.map { ($0.menu.items[$0.index].keyEquivalent, $0.menu.items[$0.index].keyEquivalentModifierMask) }
        let byMenu = item.map { $0.menu.items[$0.index].isEnabled } == true
        if byMenu { _ = choose("Show Sync Details") } else { document.toggleSyncDetails() }
        _ = await waitFor(3) { document.syncDetailsShown }
        try? await Task.sleep(for: .milliseconds(600))   // the CRT's 0.36 s
        let shown = share(picture(view, "synchud.png"), view, hudBlack)
        log.check(item != nil && document.syncDetailsShown && keys?.0.lowercased() == "y" && keys?.1.contains([.command, .shift]) == true
                  && before < 0.05 && shown > 0.4,
                  "View › Show Sync Details (⇧⌘Y)\(byMenu ? "" : ", by its action (Rune not let in front, the item off)") opens it over the text's foot: \(Int(shown * 100))% of it HUD black, \(Int(before * 100))% before")

        // Escape closes it; the menu opens it and closes it again.
        view.window?.makeFirstResponder(view)
        view.cancelOperation(nil)
        try? await Task.sleep(for: .milliseconds(600))
        let closed = share(picture(view, ""), view, hudBlack)
        let escaped = !document.syncDetailsShown
        if byMenu { _ = choose("Show Sync Details") } else { document.toggleSyncDetails() }
        let again = await waitFor(3) { document.syncDetailsShown }
        // SwiftUI names the item again on its next pass.
        var renamed = !byMenu
        if byMenu { renamed = await waitFor(3) { menuItem("Hide Sync Details") != nil } }
        if byMenu { _ = choose("Hide Sync Details") } else { document.toggleSyncDetails() }
        let hidden = await waitFor(3) { !document.syncDetailsShown }
        log.check(escaped && closed < 0.05 && again && renamed && hidden,
                  "Escape closes it (\(Int(closed * 100))% left), and \(byMenu ? "the menu" : "its action") opens it and\(byMenu ? ", as Hide Sync Details," : "") closes it")

        // A conflict block: the WARNING panel, at the log's height; Escape takes the HUD first.
        let text = "# Sync HUD \(marker)\n\n<<<<<<< This Mac · 10:42\nmine\n=======\ntheirs\n>>>>>>> Test Mac · 10:43\n"
        guard let url = Untitled.create(text: text, name: "synchud-\(marker).md") else { log.check(false, "a buffer with a conflict block"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let buffer = Documents.existing(for: url) else {
            log.check(false, "it opened")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())   // or it comes back at the next launch
            return
        }
        let bufferView = buffer.editor.textView
        _ = await waitFor(5) { buffer.blocks.count == 1 }
        buffer.toggleSyncDetails()
        try? await Task.sleep(for: .milliseconds(600))
        let red = share(picture(bufferView, "synchud-warning.png"), bufferView, failureRed)
        bufferView.window?.makeFirstResponder(bufferView)
        bufferView.cancelOperation(nil)
        let hudFirst = !buffer.syncDetailsShown && !buffer.bannerHidden
        log.check(buffer.blocks.count == 1 && red > 0.08 && hudFirst,
                  "a conflict block adds the WARNING panel (\(Int(red * 100))% of the band its red), and Escape closes the HUD before the banner")
        // Then the find bar before the banner (the QA review's F32: the banner went first, the bar
        // staying), and the banner last.
        buffer.editor.find.open(replace: false)
        bufferView.window?.makeFirstResponder(bufferView)
        bufferView.cancelOperation(nil)
        let barFirst = !buffer.editor.find.shown && !buffer.bannerHidden
        bufferView.cancelOperation(nil)
        log.check(barFirst && buffer.bannerHidden, "Escape closes the find bar before the banner, and the banner last")
        // The banner's sentence, from the blocks' whole names (the QA review's F10: "This Mac and
        // this Mac both changed this file", the file after a crash, a duplicate, "Studio 2").
        let me = buffer.device
        func said(_ labels: [String], device: String? = nil) -> String {
            ConflictBanner.message(blocks: 1, others: ConflictBanner.others(labels, device: device ?? me), merged: false, fileExtension: "md")
        }
        let sayings = [said(["This Mac · 10:42", "Test Mac · 10:43"]), said(["\(me) · 10:42", "The file · now"]),
                       said(["\(me) · 10:42", "scratch-test 2.md · 10:40"]), said(["Studio · 10:42", "Studio 2 · 10:43"], device: "Studio"),
                       said(["\(me) · 10:42", "Air · 10:41", "\(me) · 10:44", "iCloud · 10:43"])]
        log.check(sayings[0].hasPrefix("Test Mac and this Mac both changed") && sayings[1].hasPrefix("The file changed while Rune was closed")
                  && sayings[2].hasPrefix("“scratch-test 2.md” is a copy of this file") && sayings[3].hasPrefix("Studio 2 and this Mac")
                  && sayings[4].hasPrefix("Several versions changed this file"),
                  "the banner names the other side by its whole name: \(sayings.map { "“\($0.prefix(40))…”" }.joined(separator: ", "))")
        Untitled.letGo(url)
        bufferView.window?.performClose(nil)
        if !(await waitFor(15) { !FileManager.default.fileExists(atPath: url.path) }) { log.line("the buffer was still there after 15 s") }
        document.syncDetailsShown = false
    }

    /// Open question 15: Settings › Files makes Nib the app a double-click opens, a kind of file at
    /// a time, and gives a kind back to the app it had. A test run's Nib changes only its stand-in:
    /// the Mac's own default apps are the same after.
    static func defaultAppsScenario(_ log: HarnessLog, _ marker: String) async {
        let apps = DefaultApps.shared
        let kinds = DefaultApps.Kind.allCases
        let types = kinds.flatMap(\.types)
        func macs() -> [String] { types.map { NSWorkspace.shared.urlForApplication(toOpen: $0)?.path ?? "none" } }
        let before = macs()
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        defer {
            for type in types { NibDefaults.store.removeObject(forKey: DefaultApps.beforeKey(type)) }
        }
        for kind in kinds { apps.pretend(textEdit, opens: kind) }
        // Not HTML (2026-10-07, the user's call): pages on this Mac opened as source.
        log.check(types.count == 8 && !types.contains { $0.identifier == "public.html" } && kinds.allSatisfy { apps.openers[$0] == .init(name: "TextEdit", isNib: false) },
                  "six kinds, eight types, not HTML (\(types.map(\.identifier).joined(separator: ", "))), each opening in TextEdit to start with")

        // On: Nib opens them, and TextEdit is remembered. Off: TextEdit has them back.
        let markdown = DefaultApps.Kind.markdown.types[0]
        await apps.set(.markdown, true)
        log.check(apps.openers[.markdown]?.isNib == true && apps.opener(of: markdown).map(DefaultApps.isNib) == true
                  && NibDefaults.store.string(forKey: DefaultApps.beforeKey(markdown)) == textEdit.path && apps.openers[.text]?.isNib == false,
                  "Markdown on: .md files open in Rune, TextEdit remembered, and plain text still TextEdit's")
        await apps.set(.markdown, false)
        log.check(apps.openers[.markdown] == .init(name: "TextEdit", isNib: false) && apps.failure == nil, "Markdown off: back to TextEdit")

        // A kind of three types: all three.
        let shell = DefaultApps.Kind.shell.types
        await apps.set(.shell, true)
        log.check(shell.allSatisfy { apps.opener(of: $0).map(DefaultApps.isNib) == true } && apps.openers[.shell]?.isNib == true,
                  "Shell scripts on: .sh, .zsh and .bash files all open in Rune")
        // One of them declined (macOS asks for each): the row says which are still elsewhere, not
        // "now Xcode" as if none were (the QA review's F69).
        apps.pretend(textEdit, opensType: "public.zsh-script")
        apps.refresh()
        let mixed = DefaultApps.Kind.shell.detail(apps.openers[.shell])
        log.check(apps.openers[.shell]?.isNib == false && mixed == ".sh, .zsh, .bash · .zsh still with TextEdit"
                  && DefaultApps.Kind.text.inSentence == "plain text files" && DefaultApps.Kind.markdown.extensions == ".md, .markdown",
                  "one of three declined: “\(mixed)”; and the kinds' words, “\(DefaultApps.Kind.shell.inSentence)”, “\(DefaultApps.Kind.markdown.extensions)”")
        apps.pretend(Bundle.main.bundleURL, opensType: "public.zsh-script")
        apps.refresh()

        // The app one had is gone: the one macOS ranks next, never Nib.
        NibDefaults.store.set("/Applications/Gone \(marker).app", forKey: DefaultApps.beforeKey(shell[0]))
        await apps.set(.shell, false)
        let next = apps.opener(of: shell[0])
        log.check(next.map(DefaultApps.isNib) == false && apps.openers[.shell]?.isNib == false
                  && shell.dropFirst().allSatisfy { apps.opener(of: $0)?.path == textEdit.path },
                  "Shell scripts off, the app .sh files had gone: the one macOS ranks next (\(next.map(DefaultApps.name) ?? "none")); .zsh and .bash back to TextEdit")

        // Settings › Files (a picture: build/scenarios/settings-files.png).
        NibDefaults.store.set("files", forKey: "settingsTab")
        AppDelegate.openSettings()
        func settingsWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Files" } }
        let shown = await waitFor(5) { settingsWindow() != nil }
        var plainHeight: CGFloat = 0
        if let window = settingsWindow(), let view = window.contentView {
            try? await Task.sleep(for: .milliseconds(400))
            plainHeight = window.frame.height
            // With Settings in front the text commands are off (the QA review's F46: on, doing nothing).
            if NSApp.isActive, window.isKeyWindow, let text = NSApp.mainMenu?.items.first(where: { $0.title == "Text" })?.submenu {
                text.update()
                let on = ["Indent", "Toggle Comment", "Select Line"].filter { title in text.items.first { $0.title == title }?.isEnabled == true }
                log.check(on.isEmpty, "with Settings in front, Text's commands are off\(on.isEmpty ? "" : ": \(on.joined(separator: ", ")) on")")
            } else {
                log.line("skipped: Text's commands with Settings in front (Rune isn't in front)")
            }
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("settings-files.png"))
            }
            window.close()
        }
        log.check(shown, "Settings › Files shows them")
        log.check(plainHeight > 0 && plainHeight <= 860, "Settings › Files fits the Air's screen (\(Int(plainHeight)) points)")
        // A Mac where Nib had HTML: given back once, to the app it took it from (the stand-in's).
        let html = UTType("public.html")!
        apps.pretend(Bundle.main.bundleURL, opensType: html.identifier)
        NibDefaults.store.set(textEdit.path, forKey: DefaultApps.beforeKey(html))
        NibDefaults.store.removeObject(forKey: DefaultApps.htmlGivenBackKey)
        let said = await apps.giveBackHTML() ?? ""
        let backTo = apps.opener(of: html).map(DefaultApps.name) ?? "none"
        let again = await apps.giveBackHTML()
        NibDefaults.store.removeObject(forKey: DefaultApps.beforeKey(html))
        log.check(backTo == "TextEdit" && said.hasPrefix("HTML FILES OPEN IN TEXTEDIT AGAIN") && again == nil,
                  "where Rune had HTML, it's given back once, to the app it took it from (\(backTo)): \(said)")

        // Every tab on the Air's screen (about 900 points under its menu bar): Settings can't scroll,
        // and General was 967 points tall (the QA review's F22). A picture of each.
        var heights: [String] = []
        var tooTall = false
        for (tag, title) in [("general", "General"), ("sync", "Sync"), ("files", "Files"), ("editor", "Editor"), ("themes", "Themes")] + (LicenseManager.shared.isEnforced ? [("license", "License")] : []) {
            NibDefaults.store.set(tag, forKey: "settingsTab")
            AppDelegate.openSettings()
            _ = await waitFor(5) { NSApp.windows.contains { $0.isVisible && $0.title == title } }
            try? await Task.sleep(for: .milliseconds(500))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == title }) else { heights.append("\(title) not shown"); tooTall = true; continue }
            heights.append("\(title) \(Int(window.frame.height))")
            if window.frame.height > 860 { tooTall = true }
            if let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("settings-\(tag).png"))
            }
        }
        NSApp.windows.first { $0.isVisible && $0.title == "Themes" }?.close()
        log.check(!tooTall, "every Settings tab fits the Air's screen: \(heights.joined(separator: ", ")) points")

        let after = macs()
        log.check(after == before, "the Mac's own default apps are as they were (\(Set(after.map { DefaultApps.name(URL(fileURLWithPath: $0)) }).sorted().joined(separator: ", ")))")
    }

    /// §4.9, 9 and 10: another app renames a file while it's open, typing not saved yet (saving
    /// held off), and then renames its folder: the buffer follows each time, with the typing,
    /// its caret and its History; it saves where the file is now; nothing is left, or made again,
    /// at the old path.
    static func movedScenario(_ log: HarnessLog, _ marker: String) async {
        let test = ScratchLocation.url.deletingLastPathComponent()
        let folder = test.appendingPathComponent("folder-\(marker)", isDirectory: true)
        let folderAfter = test.appendingPathComponent("folder-moved-\(marker)", isDirectory: true)
        let first = folder.appendingPathComponent("moved-\(marker).md")
        let renamed = folder.appendingPathComponent("renamed-\(marker).md")
        let last = folderAfter.appendingPathComponent("renamed-\(marker).md")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("# Moved \(marker)\n\nline three\n".utf8).write(to: first)
        defer {
            for url in [first, renamed, last] { Documents.existing(for: url)?.editor.textView.window?.performClose(nil) }
            for url in [folder, folderAfter] { try? FileManager.default.removeItem(at: url) }
            for url in [first, renamed, last] {
                for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
                if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
                RecentFiles.shared.remove(url)
            }
        }
        AppDelegate.openFile(first)
        _ = await waitFor(30) { Documents.existing(for: first)?.ready == true && Documents.existing(for: first)?.held == true }
        guard let document = Documents.existing(for: first) else { log.check(false, "the file opened and was held"); return }
        await waitSynced(document, 30)
        let historyBefore = document.history.entries().count
        await type("\n- typed before the move \(marker)\n", into: document)
        try? await Task.sleep(for: .milliseconds(600))   // in the journal; not saved (held off)
        document.editor.textView.setSelectedRange(NSRange(location: 3, length: 0))

        // Renamed by another app, coordinated as Finder does.
        do {
            try await CloudControl.within(20) { try FileCommands.coordinatedMove(first, to: renamed, caseOnly: false) }
        } catch {
            log.check(false, "the rename by another app: \(error.localizedDescription)")
            return
        }
        let followed = await waitFor(20) { Documents.existing(for: renamed)?.ready == true }
        let after = Documents.existing(for: renamed)
        log.check(followed && Documents.existing(for: first) == nil && after?.editor.textView.string.contains("typed before the move \(marker)") == true,
                  "renamed by another app: the buffer follows it, with the typing not saved yet")
        guard let after else { return }
        log.check(after.editor.textView.selectedRange().location == 3 && after.history.entries().count >= historyBefore,
                  "its caret and History go with it (caret at \(after.editor.textView.selectedRange().location), \(after.history.entries().count) versions)")
        await after.flush(reason: "test")
        log.check(fileText(after).contains("typed before the move \(marker)") && !FileManager.default.fileExists(atPath: first.path),
                  "the typing is saved into the file where it is now, and nothing is at the old name")

        // Then its folder, renamed.
        do {
            try await CloudControl.within(20) { try FileCommands.coordinatedMove(folder, to: folderAfter, caseOnly: false) }
        } catch {
            log.check(false, "the folder's rename by another app: \(error.localizedDescription)")
            return
        }
        let followedAgain = await waitFor(20) { Documents.existing(for: last)?.ready == true }
        guard followedAgain, let moved = Documents.existing(for: last) else {
            log.check(false, "its folder renamed: the buffer follows it there too (open: \(Documents.all.map(\.url.lastPathComponent)))")
            return
        }
        await type("- typed after the folder moved \(marker)\n", into: moved)
        await moved.flush(reason: "test")
        log.check(fileText(moved).contains("typed after the folder moved \(marker)") && fileText(moved).contains("typed before the move \(marker)")
                  && !FileManager.default.fileExists(atPath: folder.path),
                  "its folder renamed: the buffer follows it there too, and saves there")
        // A renamed folder keeps iCloud busy for a while: it said the file was paused when it
        // wasn't, refused uploads, and its helper stopped answering (the suite, 2026-09-30, 22:24).
        await waitSynced(moved, 60)
        log.check(isSynced(moved), "and it's synced (\(moved.state.line))")
    }

    /// §4.8 E, §4.9 8: another app moves a file to the Trash while it's open, typing not saved
    /// yet (saving held off): the text stays, the banner and the strip say so, and saving makes
    /// nothing at the path; Restore writes it all back, held and synced. Then it's deleted outright,
    /// and closed: its text on Reopen Closed File, no file made again, no journal left. Reopened
    /// (⇧⌘T) with a file there again, that one opens as it is and the text comes back beside it;
    /// with the same text there, nothing beside it; with nothing there, it's written back.
    static func deletedScenario(_ log: HarnessLog, _ marker: String) async {
        let folder = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("deleted-\(marker)", isDirectory: true)
        let url = folder.appendingPathComponent("gone-\(marker).md")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("# Gone \(marker)\n".utf8).write(to: url)
        var trashed: URL?
        defer {
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            try? FileManager.default.removeItem(at: folder)
            if let trashed { try? FileManager.default.removeItem(at: trashed) }
            for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
            for item in ClosedItems.shared.items where item.path == url.path { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(url)
            for buffer in Untitled.all() where buffer.lastPathComponent.hasPrefix("gone-\(marker) (closed)") {
                Untitled.letGo(buffer)
                Documents.existing(for: buffer)?.editor.textView.window?.performClose(nil)
            }
        }
        AppDelegate.openFile(url)
        _ = await waitFor(30) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.held == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened and was held"); return }
        await waitSynced(document, 30)
        await type("\n- typed before it went \(marker)\n", into: document)
        try? await Task.sleep(for: .milliseconds(600))

        // To the Trash, as Finder does it: a move, coordinated, into the Trash for that file.
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: url, create: false) else {
            log.check(false, "a Trash for the test folder")
            return
        }
        trashed = trash.appendingPathComponent("gone-\(marker).md")
        do {
            try await CloudControl.within(20) { try FileCommands.coordinatedMove(url, to: trash.appendingPathComponent("gone-\(marker).md"), caseOnly: false) }
        } catch {
            log.check(false, "the move to the Trash by another app: \(error.localizedDescription)")
            return
        }
        let banner = await waitFor(10) { document.deleted }
        // The window as a picture beside the log, to look at (its own window only).
        try? await Task.sleep(for: .milliseconds(500))
        if let frame = document.editor.textView.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("deleted-banner.png"))
        }
        log.check(banner && document.deletedToTrash && document.state.line.contains("MOVED TO THE TRASH") && !document.held,
                  "moved to the Trash by another app: the text stays, and the banner and the strip say so (\(document.state.line))")
        // The HUD says it too (the QA review's F12: "✕ PROBLEM", and the file "CURRENT").
        log.check(SyncHUD.stateWord(document.state) == "✕ IN THE TRASH" && SyncHUD.onDisk(document) == "GONE",
                  "the sync HUD: STATE \(SyncHUD.stateWord(document.state)), ON DISK \(SyncHUD.onDisk(document))")
        func gone() -> [Alerts.Alert] { Notifier.shared.posted.filter { $0.kind == .deleted && $0.title.hasPrefix("“gone-\(marker).md”") } }
        log.check(gone().map(\.title) == ["“gone-\(marker).md” was moved to the Trash"], "and a notification (SY15): “\(gone().first.map { $0.title + ": " + $0.body } ?? "none")”")
        await document.flush(reason: "test")
        log.check(!FileManager.default.fileExists(atPath: url.path) && document.editor.textView.string.contains("typed before it went \(marker)"),
                  "saving makes nothing at the path, and the text is all here")
        await type("- typed after it went \(marker)\n", into: document)
        // Typing doesn't take the red line away (the QA review's F5: the first keystroke made it
        // "· EDITING", for good), nor the menu bar's ✕.
        try? await Task.sleep(for: .milliseconds(1_500))
        log.check(document.state.line.contains("MOVED TO THE TRASH") && MenuBarState.needsLook(document),
                  "typing after it went keeps the strip's red line (\(document.state.line)) and the menu bar's ✕")
        // The menu bar names it: its panel and tooltip spoke only of the scratch file (the QA review's F11).
        let others = MenuBarState.othersNeedingLook()
        let named = MenuBarState.othersLine(others) ?? ""
        log.check(others.contains { $0 === document } && named.contains("GONE-\(marker.uppercased()).MD NEEDS A LOOK (IN THE TRASH)"),
                  "and the menu bar's panel and tooltip name it: \(named)")
        await document.restoreDeleted()
        let restored = fileText(document)
        log.check(!document.deleted && restored.contains("typed before it went \(marker)") && restored.contains("typed after it went \(marker)"),
                  "Restore writes it all back where it was")
        let resynced = await waitFor(60) { document.held && isSynced(document) }
        log.check(resynced, "and it's held and synced again (\(document.state.line), held \(document.held))")
        log.check(Notifier.shared.withdrawn.filter { $0 == .deleted }.count == 1, "restored, its notification is taken back")

        // Deleted outright, then closed.
        await type("- typed before it went again \(marker)\n", into: document)
        try? await Task.sleep(for: .milliseconds(600))
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            try? FileManager.default.removeItem(at: target)
        }
        let deletedAgain = await waitFor(10) { document.deleted }
        log.check(deletedAgain && !document.deletedToTrash && document.state.line.contains("DELETED ·"), "deleted outright: the banner again (\(document.state.line))")
        log.check(gone().last?.title == "“gone-\(marker).md” was deleted" && gone().count == 2, "and a notification again: it's news again once it was over")
        document.editor.textView.window?.performClose(nil)
        let closed = await waitFor(10) { Documents.existing(for: url) == nil }
        log.check(Notifier.shared.withdrawn.filter { $0 == .deleted }.count == 2, "closed, that one's taken back too")
        let item = ClosedItems.shared.items.first { $0.path == url.path }
        let history = History(root: NibPaths.support.appendingPathComponent("History"), path: url.path)
        let kept = item?.sha256.flatMap { history.data($0) }.map { String(decoding: $0, as: UTF8.self) }
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        log.check(closed && item?.untitled == true && kept?.contains("typed before it went again \(marker)") == true
                  && !FileManager.default.fileExists(atPath: url.path) && journal.read(path: url.path) == nil,
                  "closed: its text is on Reopen Closed File, nothing is made at the path, and no journal is left")
        guard let item, let kept else { return }

        // ⇧⌘T with a file there again (another app made it anew): it opens as it is, never
        // written over, and the text closed with the deleted one comes back beside it.
        func onDisk() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func besides() -> [URL] { Untitled.all().filter { $0.lastPathComponent.hasPrefix("gone-\(marker) (closed)") } }
        func close(_ file: URL) async {
            if Untitled.contains(file) { Untitled.letGo(file) }
            Documents.existing(for: file)?.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: file) == nil }
        }
        let anew = "# Made anew by another app \(marker)\n"
        try? Data(anew.utf8).write(to: url)
        ClosedItems.shared.reopen(item)
        let beside = await waitFor(20) { besides().first.flatMap { Documents.existing(for: $0) }?.ready == true }
        let besideText = besides().first.flatMap { Documents.existing(for: $0) }?.editor.textView.string
        log.check(beside && onDisk() == anew && Documents.existing(for: url)?.editor.textView.string == anew && besideText == kept
                  && besides().first?.lastPathComponent == "gone-\(marker) (closed).md" && !ClosedItems.shared.items.contains { $0.path == url.path },
                  "⇧⌘T with a file there again: it opens as it is, not written over, and the text it was closed with comes back beside it (\(besides().first?.lastPathComponent ?? "none"))")
        for buffer in besides() { await close(buffer) }

        // With the same text there: that file, and nothing beside it.
        await close(url)
        try? history.record(Data(anew.utf8), parent: nil, source: "deleted elsewhere")
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: Digest.sha256(Data(anew.utf8)), time: Date()))
        ClosedItems.shared.reopen(ClosedItems.shared.items[0])
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true }
        try? await Task.sleep(for: .seconds(2))   // time enough for a buffer beside it to come
        log.check(Documents.existing(for: url)?.editor.textView.string == anew && besides().isEmpty && onDisk() == anew,
                  "with the same text there: that file, nothing beside it")

        // With nothing there: written back where it was, and opened.
        await close(url)
        try? FileManager.default.removeItem(at: url)
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: item.sha256, time: Date()))
        ClosedItems.shared.reopen(ClosedItems.shared.items[0])
        let back = await waitFor(15) { Documents.existing(for: url)?.ready == true }
        let shown = Documents.existing(for: url)?.editor.textView.string
        log.check(back && onDisk() == kept && shown == kept && besides().isEmpty,
                  "with nothing there: written back where it was, and opened (opened \(back), on disk \(onDisk() == kept ? "the text" : "\(onDisk().count) characters, not the text"), shown \(shown == kept ? "the text" : "\(shown?.count ?? -1) characters"), \(besides().count) beside it)")
    }

    /// §4.9, 12 and 13: iCloud storage full, then this Mac's disk full. Storage full: saved here,
    /// the strip red, and the upload tried again until it takes. Disk full: the journal and the
    /// file both refuse; the strip says the latest changes are only in memory, and both are tried
    /// again every 15 s, typing or not, until there's room.
    static func fullScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 30)
        TestHarness.storageFull = true
        await type("\n- storage full \(marker)\n", into: document)
        await document.flush(reason: "test")
        let full = await waitFor(10) { document.state.line.contains("ICLOUD STORAGE IS FULL") }
        try? await Task.sleep(for: .seconds(2))
        log.check(full && document.state.line.contains("ICLOUD STORAGE IS FULL") && fileText(document).contains("storage full \(marker)"),
                  "iCloud storage full: saved here, and the strip says so, and goes on saying so (\(document.state.line))")
        log.check(SyncHUD.stateWord(document.state) == "✕ ICLOUD FULL" && SyncHUD.onDisk(document) == "CURRENT",
                  "the sync HUD: STATE \(SyncHUD.stateWord(document.state)), ON DISK \(SyncHUD.onDisk(document)) (F12)")
        // SY15: a notification (a scenario's Nib is never frontmost), once however often it's retried.
        func said(_ kind: Alerts.Kind) -> [Alerts.Alert] { Notifier.shared.posted.filter { $0.kind == kind } }
        log.check(said(.storageFull).map(\.title) == ["iCloud storage is full"], "a notification: “\(said(.storageFull).first.map { $0.title + ": " + $0.body } ?? "none")”")
        TestHarness.storageFull = false
        let back = await waitFor(40) { isSynced(document) }
        log.check(back, "the upload is tried again, and takes once there's room (\(document.state.line))")
        log.check(said(.storageFull).count == 1 && Notifier.shared.withdrawn.contains(.storageFull),
                  "one notification through every retry, taken out of Notification Center once it's synced (\(said(.storageFull).count))")

        // Row 13's Empty Trash, against a Trash of the scenario's own (a scenario's Nib never
        // offers or empties the Mac's, nor asks Finder), 3 MB in it.
        let trash = NibPaths.support.appendingPathComponent("Trash-\(marker)", isDirectory: true)
        let old = trash.appendingPathComponent("old-\(marker).bin")
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 3_000_000).write(to: old)
        TestHarness.fakeTrash = trash
        defer {
            TestHarness.fakeTrash = nil
            TrashService.testAnswer = nil
            try? FileManager.default.removeItem(at: trash)
        }
        TestHarness.diskFull = true
        await type("- disk full \(marker)\n", into: document)
        let journalFull = await waitFor(5) { document.state.line.contains("DISK FULL") }
        await document.flush(reason: "test")
        log.check(journalFull && document.state.line.contains("ONLY IN MEMORY") && !fileText(document).contains("disk full \(marker)"),
                  "disk full: the journal and the file refuse, and the strip says so (\(document.state.line))")
        // Not "SAVING" for good (the QA review's F12).
        log.check(SyncHUD.stateWord(document.state) == "✕ DISK FULL" && SyncHUD.onDisk(document) == "NOT SAVED · IN MEMORY",
                  "the sync HUD: STATE \(SyncHUD.stateWord(document.state)), ON DISK \(SyncHUD.onDisk(document))")
        let offered = await waitFor(5) { document.trashOffer != nil }
        log.check(offered && document.trashOffer?.label.hasPrefix("EMPTY TRASH · 3") == true,
                  "the strip offers to empty the Trash, with what that frees (\(document.trashOffer?.label ?? "nothing"))")
        TrashService.testAnswer = false
        await document.emptyTrashForSpace()
        log.check(FileManager.default.fileExists(atPath: old.path) && document.trashOffer != nil, "it asks first, and Cancel erases nothing")
        try? await Task.sleep(for: .seconds(16))   // a retry, refused too
        let diskAlerts = said(.saveFailed)
        log.check(diskAlerts.count == 1 && diskAlerts[0].title == "Couldn't save “\(document.url.lastPathComponent)”" && diskAlerts[0].body.contains("disk is full"),
                  "a notification for it, once through the retries: “\(diskAlerts.first.map { $0.title + ": " + $0.body } ?? "none")” (\(diskAlerts.count))")
        // Emptied: the space back (the made-up full disk let go with it), and the save goes at
        // once, not at the next 15 s retry.
        TrashService.testAnswer = true
        TestHarness.diskFull = false
        let emptied = Date()
        await document.emptyTrashForSpace()
        let saved = await waitFor(25) { fileText(document).contains("disk full \(marker)") }
        let after = Date().timeIntervalSince(emptied)
        log.check(saved && after < 5 && !FileManager.default.fileExists(atPath: old.path) && document.trashOffer == nil,
                  "Empty Trash: erased once asked, and the text saved \(String(format: "%.1f", after)) s after, nothing typed meanwhile (\(document.notice ?? document.state.line))")
        await waitSynced(document, 30)
        log.check(isSynced(document), "and synced (\(document.state.line))")
        log.check(Notifier.shared.withdrawn.contains(.saveFailed) && said(.saveFailed).count == 1, "and its notification taken back")
    }

    /// §4.9, 11, simulated (turning iCloud Drive off for real is the user's to do): iCloud Drive
    /// goes off, taking an open file with it (a deletion, with no iCloud account left). The text
    /// stays, the banner and the strip say so, and saving goes to Nib's Recovery folder, never the
    /// file's place. iCloud on again, the file back as it was: the typing goes into it, held and
    /// synced, and the Recovery copy goes.
    static func iCloudOffScenario(_ log: HarnessLog, _ marker: String) async {
        let folder = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("icloudoff-\(marker)", isDirectory: true)
        let url = folder.appendingPathComponent("away-\(marker).md")
        let original = "# Away \(marker)\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(original.utf8).write(to: url)
        defer {
            TestHarness.iCloudOff = false
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            try? FileManager.default.removeItem(at: folder)
            for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
            for item in ClosedItems.shared.items where item.path == url.path { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(url)
        }
        AppDelegate.openFile(url)
        _ = await waitFor(30) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.held == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened and was held"); return }
        await waitSynced(document, 30)
        let recovery = document.recoveryURL

        // iCloud Drive off: the account gone, the file removed with it.
        TestHarness.iCloudOff = true
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            try? FileManager.default.removeItem(at: target)
        }
        let went = Date()
        let off = await waitFor(10) { document.iCloudOff }
        log.check(off && document.deleted && document.state.line.contains("ICLOUD DRIVE IS OFF"), "iCloud Drive off: the text stays, and the banner and the strip say so (\(document.state.line))")
        let offAlerts = Notifier.shared.posted.filter { $0.kind == .iCloudOff }
        log.check(offAlerts.count == 1 && offAlerts[0].body.hasPrefix("“away-\(marker).md” went with it."),
                  "and a notification (SY15): “\(offAlerts.first.map { $0.title + ": " + $0.body } ?? "none")”")
        await type("\n- typed while iCloud was off \(marker)\n", into: document)
        await document.flush(reason: "test")
        let copy = (try? String(contentsOf: recovery, encoding: .utf8)) ?? ""
        log.check(copy.contains("typed while iCloud was off \(marker)") && !FileManager.default.fileExists(atPath: url.path),
                  "saved to Rune's Recovery folder, and nothing made at the file's place")
        log.check(SyncHUD.stateWord(document.state) == "✕ ICLOUD DRIVE OFF" && SyncHUD.onDisk(document) == "IN THE RECOVERY FOLDER",
                  "the sync HUD: STATE \(SyncHUD.stateWord(document.state)), ON DISK \(SyncHUD.onDisk(document)) (F12: “SAVING” for good)")

        // iCloud on again, and the file back, as it was when it went: not a second and a half
        // after going (the typing above), as no real iCloud Drive comes back. iCloud's file
        // provider settles a held file's deletion once it has looked for its document four times,
        // the last about 1.5 s after the first; a new file at the path before then was taken for
        // the old one ("ESTALE: opened wrong doc_id"), and in 4 of 7 runs on 2026-10-02 neither
        // was ever settled: the new one never uploaded, so it couldn't be held (§8).
        let away = 10 - Date().timeIntervalSince(went)
        if away > 0 { try? await Task.sleep(for: .seconds(away)) }
        try? Data(original.utf8).write(to: url)
        TestHarness.iCloudOff = false
        NotificationCenter.default.post(name: .NSUbiquityIdentityDidChange, object: nil)
        let back = await waitFor(20) { !document.deleted }
        let merged = await waitFor(20) { fileText(document).contains("typed while iCloud was off \(marker)") }
        log.check(back && merged && document.editor.textView.string.contains("typed while iCloud was off \(marker)"),
                  "iCloud on again, the file back: the typing goes into it")
        let synced = await waitFor(60) { document.held && isSynced(document) }
        let holds = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().filter { $0.path == url.path && $0.event == "pause" }
        log.check(synced && !FileManager.default.fileExists(atPath: recovery.path),
                  "held and synced again, and the Recovery copy is gone (\(document.state.line); the last hold: \(holds.last?.detail ?? "held"))")
        log.check(Notifier.shared.withdrawn.contains(.iCloudOff), "and the notification's taken back")
    }

    /// ED9, large files. Up to 5 MB, every feature: here the one most at risk at that size, Find
    /// All on 10,000 matches and a keystroke and a delete at all of them. From 5 to 100 MB: no
    /// highlighting, the strip saying so with the size, still editable, and History keeping the
    /// version opened, not every save. Over 100 MB: asked first.
    static func largeScenario(_ log: HarnessLog, _ marker: String) async {
        func close(_ url: URL) async {
            Untitled.letGo(url)
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            // Its file gone too: a 42 MB buffer still closing at the quit came back at every launch after (2026-10-02).
            _ = await waitFor(30) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
            // And its History (the versions opened and closed with): nothing opens that path again,
            // and each run had left 92 MB in the scenarios' History, 1.4 GB in a day (2026-10-02).
            try? FileManager.default.removeItem(at: History(root: NibPaths.support.appendingPathComponent("History"), path: url.path).directory)
        }
        func ms(_ t: TimeInterval) -> String { "\(Int((t * 1000).rounded())) ms" }
        func open(_ url: URL) async -> (Document, TimeInterval)? {
            let asked = Date()
            AppDelegate.openFile(url)
            _ = await waitFor(90) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url).map { ($0, Date().timeIntervalSince(asked)) }
        }

        // Up to 5 MB: highlighted, and Find All and typing at every match.
        var js = "", n = 0
        while js.utf8.count < 4_900_000 {
            n += 1
            js += "function handler\(n)(event) { const value = event.detail ?? \(n); return value > 10 ? \"big\" : \"small\"; }\n"
        }
        guard let smallURL = Untitled.create(text: js, name: "large-\(marker).js"), let (near, nearOpen) = await open(smallURL) else {
            log.check(false, "a 4.9 MB untitled buffer opened")
            return
        }
        let view = near.editor.textView
        log.check(!near.highlightingOff && near.syntaxName == "JAVASCRIPT", "4.9 MB: opened in \(ms(nearOpen)), highlighted (\(near.syntaxName)), as every file up to 5 MB")
        let find = near.editor.find
        find.open(replace: false)
        find.query = "value"
        var started = Date()
        find.findAll()
        let allTime = Date().timeIntervalSince(started), count = view.currentCarets.count
        started = Date()
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let key = Date().timeIntervalSince(started)
        started = Date()
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        let delete = Date().timeIntervalSince(started)
        log.check(count == TextSearch.limit && key < 2 && delete < 2,
                  "Find All at 4.9 MB: \(count) matches, the most at once, in \(ms(allTime)); a keystroke at all of them \(ms(key)), a delete \(ms(delete)) (Debug)")
        find.query = ""
        view.collapseCarets()
        await close(smallURL)

        // 5 to 100 MB: no highlighting, the strip saying so with the size; still editable.
        let line = "2026-10-01T12:00:00Z INFO request served in 12 ms, status 200, path /api/items/\(marker)\n"
        let text = String(repeating: line, count: 42_000_000 / line.utf8.count)
        guard let largeURL = Untitled.create(text: text, name: "large-\(marker).log"), let (far, farOpen) = await open(largeURL) else {
            log.check(false, "a 42 MB untitled buffer opened")
            return
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(far.fileBytes), countStyle: .file).uppercased()
        log.check(far.highlightingOff && far.fileBytes > 40_000_000, "42 MB: opened in \(ms(farOpen)), no highlighting, the strip saying HIGHLIGHTING OFF · \(size)")
        let farView = far.editor.textView
        farView.setSelectedRange(NSRange(location: 0, length: 0))
        let watch = StallWatch()
        watch.start()
        started = Date()
        farView.insertText("x", replacementRange: farView.selectedRange())
        let typed = Date().timeIntervalSince(started)
        started = Date()
        await far.flush(reason: "test")
        let saved = Date().timeIntervalSince(started)
        watch.stop()
        let sources = far.history.entries().map(\.source)
        log.check(!far.dirty && sources == ["opened"],
                  "editable: a keystroke \(ms(typed)) on the main thread, saved in \(ms(saved)) (its longest wait \(ms(watch.longest))), History keeping the version opened, not each save (\(sources))")
        await close(largeURL)

        // Over 100 MB: asked first (a sparse file, outside the test folders: the question comes
        // before the safety rule's refusal, which then keeps it from being read at all).
        let huge = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("large-\(marker)-huge.txt")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: huge) {
            try? handle.truncate(atOffset: 120_000_000)
            try? handle.close()
        }
        defer {
            try? FileManager.default.removeItem(at: huge)
            TestHarness.largeFileAnswer = nil
            RecentFiles.shared.remove(huge)
        }
        TestHarness.largeFileAsked = []
        TestHarness.largeFileAnswer = false
        let refused = !AppDelegate.openFile(huge)
        log.check(refused && TestHarness.largeFileAsked == [huge.lastPathComponent] && Documents.existing(for: huge) == nil, "120 MB: asked first, and Cancel opens nothing")
        TestHarness.largeFileAnswer = true
        let accepted = AppDelegate.openFile(huge)
        _ = await waitFor(10) { Documents.existing(for: huge) != nil }
        log.check(accepted && TestHarness.largeFileAsked.count == 2 && Documents.existing(for: huge) != nil,
                  "and Open goes on to open it (outside the test folders, refused by the safety rule as any such file: \(Documents.existing(for: huge)?.state.line ?? "no window"))")
        Documents.existing(for: huge)?.editor.textView.window?.performClose(nil)
        _ = await waitFor(10) { Documents.existing(for: huge) == nil }
    }

    /// §4.9 row 7 and §4.8 F: a file taken off this Mac, as Optimize Mac Storage does. Online, it
    /// opens once iCloud brings it, the main thread never waiting on the download. Offline (as
    /// the scenario says): the copy Nib saw last, dimmed, typing allowed and the file left alone;
    /// then iCloud back, with another Mac's version meanwhile: merged with the typing from the
    /// copy's version, saved, held and synced.
    static func evictedScenario(_ log: HarnessLog, _ marker: String) async {
        let folder = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("evicted-\(marker)", isDirectory: true)
        let url = folder.appendingPathComponent("far-\(marker).md")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("# Far \(marker)\n\nthe middle line\n".utf8).write(to: url)
        await evictedSteps(log, marker, folder: folder, url: url)
        // Closed, and only then removed: removed while its window was closing, the folder stayed
        // (five were left in the test folder, 2026-10-01).
        TestHarness.offline = false
        TestHarness.slowDownload = false
        let never = folder.appendingPathComponent("never-\(marker).md")
        for file in [url, never] { Documents.existing(for: file)?.editor.textView.window?.performClose(nil) }
        _ = await waitFor(20) { Documents.existing(for: url) == nil && Documents.existing(for: never) == nil }
        try? FileManager.default.removeItem(at: folder)
        for file in [url, never] {
            for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + file.path) }
            for item in ClosedItems.shared.items where item.path == file.path { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(file)
        }
    }

    private static func evictedSteps(_ log: HarnessLog, _ marker: String, folder: URL, url: URL) async {
        func open() async -> Document? {
            AppDelegate.openFile(url)
            _ = await waitFor(40) { Documents.existing(for: url)?.ready == true }
            return Documents.existing(for: url)
        }
        func close(_ document: Document) async {
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(20) { Documents.existing(for: url) == nil }
        }
        /// Off this Mac, as Optimize Mac Storage takes it. iCloud refuses for a while after an
        /// upload or a hand-back, so it's tried again, for up to a minute.
        func evict() async -> Bool {
            for _ in 0..<30 {
                if (try? FileManager.default.evictUbiquitousItem(at: url)) != nil,
                   await waitFor(5, { CloudControl.status(url).downloadStatus == "notDownloaded" }) { return true }
                try? await Task.sleep(for: .seconds(2))
            }
            return false
        }

        // Opened, a line typed, synced, closed: History has that version, and iCloud the file.
        guard let first = await open() else { log.check(false, "the file opened"); return }
        await waitSynced(first, 30)
        await type("- typed before it went \(marker)\n", into: first)
        await first.flush(reason: "test")
        await waitSynced(first, 30)
        let synced = first.editor.textView.string
        await close(first)
        let gone = await evict()
        log.check(gone, "taken off this Mac, as Optimize Mac Storage does (\(CloudControl.status(url).downloadStatus))")
        guard gone else { return }

        // Online: it opens once iCloud brings it, and the main thread never waits on the download.
        let watch = StallWatch()
        watch.start()
        let asked = Date()
        guard let second = await open() else { watch.stop(); log.check(false, "the evicted file opened"); return }
        let here = await waitFor(30) { !second.awaitingDownload && second.editor.textView.string == synced }
        let took = Date().timeIntervalSince(asked)
        watch.stop()
        log.check(here && watch.longest < 1, "online: it opens once iCloud brings it, \(String(format: "%.1f", took)) s, the main thread's longest wait \(Int(watch.longest * 1000)) ms")
        await waitSynced(second, 30)
        await close(second)
        let goneAgain = await evict()
        log.check(goneAgain, "taken off this Mac again")
        guard goneAgain else { return }

        // Online, and iCloud slow to bring it: the copy, said as not here yet, not as offline (the
        // QA review's F15: "◐ OFFLINE" on a Mac that's online). Closed before iCloud's asked.
        TestHarness.slowDownload = true
        if let slow = await open() {
            let said = await waitFor(10) { slow.awaitingDownload }
            log.check(said && slow.state.line.hasPrefix("◐ NOT HERE YET · ICLOUD IS SLOW TO BRING IT · SHOWING THE COPY FROM") && SyncHUD.stateWord(slow.state) == "◐ NOT HERE YET",
                      "online, iCloud slow to bring it: the copy, not here yet rather than offline (\(slow.state.line))")
            await close(slow)
        } else {
            log.check(false, "it opened with iCloud slow")
        }
        TestHarness.slowDownload = false

        // Offline: the copy Nib saw last, dimmed; typing allowed, and the file left alone.
        TestHarness.offline = true
        guard let third = await open() else { log.check(false, "it opened offline"); return }
        let view = third.editor.textView
        let copy = await waitFor(10) { third.state.line.hasPrefix("◐ OFFLINE · SHOWING THE COPY FROM") }
        log.check(copy && third.awaitingDownload && view.string == synced && view.alphaValue < 1 && view.isEditable,
                  "offline: the copy Rune saw last, dimmed, and typing allowed (\(third.state.line))")
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("- typed offline \(marker)\n", replacementRange: view.selectedRange())
        await endOfEvent(view)
        try? await Task.sleep(for: .seconds(2))
        // What Nib did, from its Sync Log (iCloud may bring the file back by itself meanwhile, just
        // after a hand-back: the suite, 2026-10-01).
        let touched = events.read().dropFirst(before).filter { $0.path == url.path && ["save", "reload", "pause", "upload", "merge"].contains($0.event) }.map(\.event)
        log.check(third.dirty && third.awaitingDownload && touched.isEmpty && third.state.line.hasPrefix("◐ OFFLINE"),
                  "the typing goes into the journal, the strip still says so, and Rune neither reads nor writes the file (\(touched.isEmpty ? "nothing in the Sync Log" : touched.joined(separator: ", ")); iCloud: \(CloudControl.status(url).downloadStatus))")

        // Meanwhile another Mac's version: the copy and a line at its end, with its note. Writing
        // it here brings the file back as a download would; Nib leaves it until iCloud's back.
        let format = third.format
        let theirs = TextFile.encode(synced + "- typed on the other Mac \(marker)\n", as: format)
        let note = Announcement(sha256: Digest.sha256(theirs), parent: Digest.sha256(TextFile.encode(synced, as: format)), device: "Test Mac", size: theirs.count)
        try? note.write(for: url)
        try? theirs.write(to: url)
        try? await Task.sleep(for: .seconds(2))
        log.check(third.awaitingDownload && !view.string.contains("typed on the other Mac \(marker)"), "while offline, the version that came isn't taken in")

        // iCloud back: the file is taken in, merged with the typing from the copy's version.
        TestHarness.offline = false
        let merged = await waitFor(40) {
            !third.awaitingDownload && view.string.contains("typed offline \(marker)") && view.string.contains("typed on the other Mac \(marker)")
        }
        log.check(merged && view.alphaValue == 1 && third.blocks.isEmpty, "iCloud back: the file comes, merged with the typing from the copy's version (\(third.notice ?? third.state.line))")
        let saved = await waitFor(30) {
            let text = fileText(third)
            return text.contains("typed offline \(marker)") && text.contains("typed on the other Mac \(marker)")
        }
        // (Held once iCloud has the upload, as a first hold is, §4.3: seconds after it's synced.)
        let settled = await waitFor(40) { third.held && isSynced(third) }
        log.check(saved && settled, "saved, held and synced (\(third.state.line), held \(third.held))")
        TestHarness.offline = false

        // A file Nib never opened on this Mac, off it and offline: no copy to show, so the window
        // waits, saying so, and it opens once iCloud's back.
        let never = folder.appendingPathComponent("never-\(marker).md")
        try? Data("# Never opened \(marker)\n".utf8).write(to: never)
        let uploaded = await waitFor(60) { CloudControl.status(never).uploaded }
        var evicted = false
        for _ in 0..<30 where uploaded && !evicted {
            if (try? FileManager.default.evictUbiquitousItem(at: never)) != nil, await waitFor(5, { CloudControl.status(never).downloadStatus == "notDownloaded" }) { evicted = true }
            else { try? await Task.sleep(for: .seconds(2)) }
        }
        guard evicted else { log.check(false, "a file Rune never opened, taken off this Mac (uploaded \(uploaded))"); return }
        TestHarness.offline = true
        AppDelegate.openFile(never)
        let waiting = await waitFor(30) { Documents.existing(for: never)?.state.line == "‖ NOT ON THIS MAC · OFFLINE · IT OPENS WHEN ICLOUD RETURNS" }
        let unopened = Documents.existing(for: never)
        log.check(waiting && unopened?.editor.textView.isEditable == false && unopened?.ready == false,
                  "offline, a file Rune never saw here: no copy, so the window waits, saying so (\(unopened?.state.line ?? "no window"))")
        TestHarness.offline = false
        let opened = await waitFor(40) { Documents.existing(for: never)?.ready == true && Documents.existing(for: never)?.editor.textView.string == "# Never opened \(marker)\n" }
        log.check(opened && Documents.existing(for: never)?.editor.textView.isEditable == true, "iCloud back: it opens (\(Documents.existing(for: never)?.state.line ?? "no window"))")
    }

    /// Multiple carets (ED8), in an untitled buffer: the Selection menu's keys; typing at three
    /// carets, a run of it one undo step; ⌘D from a caret (whole words) and replacing each; ⇧⌘L
    /// and ⌘→ to end every line; ⌃⇧↓ for a column; the arrows, ⇧ extending; deleting where
    /// carets meet; copy and paste a line each; Escape, and a plain click, back to one; ⌘-click
    /// adding and taking away; an ⌥-drag column; the strip's count.
    static func caretsScenario(_ log: HarnessLog, _ marker: String) async {
        let start = "alpha\nbeta\ngamma\ndelta\nlet name = name + rename; name\n"
        guard let url = Untitled.create(text: start, name: "carets-\(marker).txt") else { log.check(false, "an untitled buffer"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "it opened"); return }
        let view = document.editor.textView
        let undo = view.undoManager
        func type(_ text: String) { for c in text { view.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        func command(_ selector: Selector) { view.doCommand(by: selector) }
        func heads() -> [Int] { view.currentCarets.all.map(\.head) }

        // The menu, on Sublime's keys.
        let menu = NSApp.mainMenu?.items.first { $0.title == "Selection" }?.submenu
        func key(_ title: String) -> String { menu?.items.first { $0.title == title }.map { "\($0.keyEquivalentModifierMask.rawValue)/\($0.keyEquivalent)" } ?? "none" }
        log.check(menu?.items.first { $0.title == "Add Next Occurrence" }?.keyEquivalent == "d" && menu?.items.first { $0.title == "Split into Lines" }?.keyEquivalent.lowercased() == "l"
                  && menu?.items.contains { $0.title == "Add Caret Below" } == true,
                  "Selection: Add Next Occurrence ⌘D, Select All Occurrences ⌃⌘G, Split into Lines ⇧⌘L, Add Caret Above and Below ⌃⇧↑↓ (\(key("Add Next Occurrence")), \(key("Select All Occurrences")), \(key("Split into Lines")))")

        // Three carets, at the starts of alpha, beta and gamma; typing at each, one undo step.
        view.setCarets(Carets([Caret(0), Caret(6), Caret(11)]))
        type("- ")
        log.check(view.string.hasPrefix("- alpha\n- beta\n- gamma\n") && heads() == [2, 10, 17] && document.caretCount == 3,
                  "three carets: typing goes in at each (\(document.caretCount) carets on the strip: \(document.statusLine.isEmpty ? "" : "LN \(document.cursor.line)"))")
        undo?.undo()
        log.check(view.string == start && heads() == [0, 6, 11], "one undo takes the whole run back, and puts the three carets back")
        undo?.redo()
        log.check(view.string.hasPrefix("- alpha\n- beta\n- gamma\n") && heads() == [2, 10, 17], "and redo makes it again")
        undo?.undo()

        // ⌃E, ⌃A and ⌥↓ (macOS's paragraph moves): every caret to its own line's end or start; they
        // collapsed the carets to one (the QA review's F30).
        view.setCarets(Carets([Caret(2), Caret(8), Caret(13)]))   // inside alpha, beta and gamma
        command(#selector(NSResponder.moveToEndOfParagraph(_:)))
        let ends = heads()
        command(#selector(NSResponder.moveToBeginningOfParagraph(_:)))
        let starts = heads()
        command(#selector(NSResponder.moveForward(_:)))   // ⌥↓ as macOS sends it: on a character, then to the end
        command(#selector(NSResponder.moveToEndOfParagraph(_:)))
        let down = heads()
        log.check(ends == [5, 10, 16] && starts == [0, 6, 11] && down == [5, 10, 16] && view.currentCarets.count == 3,
                  "⌃E, ⌃A and ⌥↓ move each of three carets on its own line (ends \(ends), starts \(starts), ⌥↓ \(down))")

        // ⌘D: from a caret, its word; then each next one, whole words only (not rename).
        let line = (start as NSString).range(of: "let name").location
        view.setCarets(Carets([Caret(line + 5)]))
        view.selectNextOccurrence(nil)
        view.selectNextOccurrence(nil)
        view.selectNextOccurrence(nil)
        let selected = view.currentCarets.ranges.map { (view.string as NSString).substring(with: $0) }
        log.check(selected == ["name", "name", "name"] && view.currentCarets.count == 3, "⌘D: the caret's word, then each next one, not \"rename\" (\(selected))")
        type("id")
        log.check(view.string.hasSuffix("let id = id + rename; id\n"), "typing replaces all three (\((view.string as NSString).substring(from: line).debugDescription))")
        undo?.undo()
        log.check(view.string == start, "one undo")

        // Skip to Next Occurrence (Sublime's ⌘K ⌘D): the one ⌘D added last goes, the next comes.
        // Then Undo Selection (⌘U) takes back each change to the carets, and Redo Selection (⇧⌘U)
        // puts it back; an edit starts them over.
        let undoKey = menu?.items.first { $0.title == "Undo Selection" }, redoKey = menu?.items.first { $0.title == "Redo Selection" }
        log.check(undoKey?.keyEquivalent == "u" && undoKey?.keyEquivalentModifierMask == .command
                  && redoKey?.keyEquivalent.lowercased() == "u" && (redoKey?.keyEquivalent == "U" || redoKey?.keyEquivalentModifierMask.contains(.shift) == true)
                  && menu?.items.contains { $0.title == "Skip to Next Occurrence" } == true,
                  "Selection: Undo Selection ⌘U, Redo Selection ⇧⌘U, Skip to Next Occurrence (\(key("Undo Selection")), \(key("Redo Selection")), \(key("Skip to Next Occurrence")))")
        let names = Occurrences.all("name", in: start as NSString, wholeWord: true).map(\.location)
        func places() -> [Int] { view.currentCarets.ranges.map(\.location) }
        // Each command its own event, as from the keys: an edit's steps start over once its event is done.
        try? await Task.sleep(for: .milliseconds(20))
        view.setCarets(Carets([Caret(line + 5)]))
        view.selectNextOccurrence(nil)
        view.selectNextOccurrence(nil)
        view.skipToNextOccurrence(nil)
        log.check(names.count == 3 && places() == [names[0], names[2]] && view.currentCarets.primaryCaret.range.location == names[2],
                  "Skip to Next Occurrence: the second \"name\" goes and the third comes in its place (\(places()), of \(names))")
        view.undoSelection(nil)
        let back1 = places()
        view.undoSelection(nil)
        let back2 = places()
        view.undoSelection(nil)
        let back3 = view.currentCarets.ranges
        view.undoSelection(nil)   // the three selections the undo above put back, before the caret was set
        let back4 = view.currentCarets.ranges
        view.undoSelection(nil)   // nothing before them: that undo's edit started the steps over (a beep)
        let back5 = view.currentCarets.ranges
        log.check(back1 == [names[0], names[1]] && back2 == [names[0]] && back3 == [NSRange(location: line + 5, length: 0)]
                  && back4 == names.map { NSRange(location: $0, length: 4) } && back5 == back4,
                  "⌘U: each change to the carets taken back, to the carets the last edit left, and no further (\(back1), \(back2), \(back3), \(back4.count) selections)")
        view.redoSelection(nil)
        view.redoSelection(nil)
        view.redoSelection(nil)
        log.check(places() == [names[0], names[1]] && view.string == start, "⇧⌘U: put back, change by change, the text untouched (\(places()))")
        type("x")
        let afterTyping = view.currentCarets.ranges
        view.undoSelection(nil)
        log.check(view.currentCarets.ranges == afterTyping, "an edit starts the steps over: ⌘U after typing leaves the carets (⌘Z is for the edit)")
        undo?.undo()
        try? await Task.sleep(for: .milliseconds(20))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        command(#selector(NSResponder.moveRight(_:)))
        command(#selector(NSResponder.moveRight(_:)))
        view.undoSelection(nil)
        log.check(view.string == start && view.carets == nil && view.selectedRange() == NSRange(location: 1, length: 0),
                  "one caret: → →, then ⌘U, one move back (\(view.selectedRange().location))")

        // ⇧⌘L on four lines, ⌘→, a semicolon each.
        view.setSelectedRange(NSRange(location: 0, length: 23))
        view.splitSelectionIntoLines(nil)
        command(#selector(NSResponder.moveToEndOfLine(_:)))
        type(";")
        log.check(view.string.hasPrefix("alpha;\nbeta;\ngamma;\ndelta;\n"), "⇧⌘L, ⌘→ and ;: each line ends with one")
        undo?.undo()

        // ⌃⇧↓ twice: a column of three.
        view.setCarets(Carets([Caret(1)]))
        view.addCaretBelow(nil)
        view.addCaretBelow(nil)
        log.check(heads() == [1, 7, 12], "⌃⇧↓ twice: carets below, at the same column (\(heads()))")
        // Arrows: right, then ⇧→ selects a character at each.
        command(#selector(NSResponder.moveRight(_:)))
        command(#selector(NSResponder.moveRightAndModifySelection(_:)))
        let picked = view.currentCarets.ranges.map { (view.string as NSString).substring(with: $0) }
        log.check(heads() == [3, 9, 14] && picked == ["p", "t", "m"], "→, then ⇧→, at every caret (\(picked))")
        // ⌘C, a caret at each line's start, ⌘V: a line each.
        view.copy(nil)
        view.setCarets(Carets([Caret(0), Caret(6), Caret(11)]))
        view.paste(nil)
        log.check(view.string.hasPrefix("palpha\ntbeta\nmgamma\n"), "copied from three, pasted at three: a line each")
        undo?.undo()

        // Deleting back from two carets side by side ("al|p|ha"): the l and the p go, and they're one.
        view.setCarets(Carets([Caret(2), Caret(3)]))
        command(#selector(NSResponder.deleteBackward(_:)))
        log.check(view.string.hasPrefix("aha\n") && view.carets == nil && view.selectedRange().location == 1 && document.caretCount == 1,
                  "deleting back from two carets side by side: both characters go, and they meet and become one")
        undo?.undo()

        // The line commands at every caret, a line once however many carets it has, each one undo step.
        let unit = view.indentation.unit, u = (unit as NSString).length
        view.setCarets(Carets([Caret(1), Caret(3), Caret(7), Caret(12)]))   // two on alpha, one on beta, one on gamma
        view.indentLines(nil)
        log.check(view.string.hasPrefix("\(unit)alpha\n\(unit)beta\n\(unit)gamma\ndelta\n") && heads() == [1 + u, 3 + u, 7 + 2 * u, 12 + 3 * u],
                  "⌘] at four carets on three lines: each line once, every caret kept in its place (\(heads()))")
        view.outdentLines(nil)
        log.check(view.string == start && heads() == [1, 3, 7, 12], "⌘[ takes it out again, the carets with it")
        undo?.undo()
        undo?.undo()
        log.check(view.string == start && heads() == [1, 3, 7, 12], "two undos, one each")
        let style = view.commentStyle
        view.commentStyle = { .line("//") }
        view.setCarets(Carets([Caret(1), Caret(12)]))
        view.toggleComment(nil)
        log.check(view.string.hasPrefix("// alpha\nbeta\n// gamma\n") && heads() == [4, 18], "⌘/ at carets on alpha and gamma: those two lines (\(heads()))")
        view.toggleComment(nil)
        log.check(view.string == start && heads() == [1, 12], "⌘/ again: uncommented")
        view.commentStyle = style
        view.duplicateLine(nil)
        log.check(view.string.hasPrefix("alpha\nalpha\nbeta\ngamma\ngamma\ndelta\n") && heads() == [7, 24], "⇧⌘D: each caret's line doubled, the carets on the copies (\(heads()))")
        undo?.undo()
        view.selectWholeLine(nil)
        let lines = view.currentCarets.ranges.map { (view.string as NSString).substring(with: $0) }
        log.check(lines == ["alpha\n", "gamma\n"], "⌘L: each caret's line (\(lines))")
        view.setCarets(Carets([Caret(1), Caret(7)]))
        view.moveLineDown(nil)
        log.check(view.string.hasPrefix("gamma\nalpha\nbeta\ndelta\n") && heads() == [7, 13], "⌃⌘↓ from carets on alpha and beta: the two lines move as one (\(heads()))")
        undo?.undo()
        view.setCarets(Carets([Caret(0), Caret(6), Caret(11)]))
        view.joinLines(nil)
        log.check(view.string.hasPrefix("alpha beta gamma delta\nlet") && view.carets == nil, "⌘J from a column of three: the four lines one, one caret")
        undo?.undo()
        log.check(view.string == start && heads() == [0, 6, 11], "undo: the lines and the three carets back")
        view.setCarets(Carets([Caret(anchor: 0, head: 8), Caret(12)]))
        command(#selector(NSResponder.insertTab(_:)))
        log.check(view.string.hasPrefix("\(unit)alpha\n\(unit)beta\n\(unit)gamma\ndelta\n"), "Tab with a selection over two lines and a caret: Indent at both")
        command(#selector(NSResponder.insertBacktab(_:)))
        log.check(view.string == start, "⇧Tab: Outdent at both")
        undo?.undo()
        undo?.undo()

        // Find All (⌥Return with the find bar open): every match, a caret each, the bar closed.
        let findAll = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Find" }?.submenu?.items.first { $0.title == "Find All" }
        let find = document.editor.find
        find.open(replace: false)
        find.options.wholeWord = true
        find.query = "name"
        find.findAll()
        let found = view.currentCarets.ranges.map { (view.string as NSString).substring(with: $0) }
        log.check(found == ["name", "name", "name"] && !find.shown && document.notice == "3 SELECTED" && findAll?.keyEquivalent == "\r" && findAll?.keyEquivalentModifierMask == .option,
                  "Find All (⌥Return): every whole-word match selected, the bar closed (\(found), \(document.notice ?? "no notice"), Edit › Find › Find All \(findAll == nil ? "missing" : "there"))")
        type("id")
        log.check(view.string.hasSuffix("let id = id + rename; id\n"), "and typing goes in at all three")
        undo?.undo()
        find.options.wholeWord = false
        find.query = ""

        // Escape, and a plain click, are one caret again.
        view.setCarets(Carets([Caret(0), Caret(6)]))
        command(#selector(NSResponder.cancelOperation(_:)))
        log.check(view.carets == nil && view.selectedRange() == NSRange(location: 6, length: 0), "Escape: one caret, the primary")
        view.setCarets(Carets([Caret(0), Caret(6)]))
        view.setSelectedRange(NSRange(location: 3, length: 0))
        log.check(view.carets == nil, "a selection Rune didn't make (a click): one caret")

        // ⌘-click adds one, ⌘-click on it takes it away.
        func click(at location: Int, _ flags: NSEvent.ModifierFlags, dragTo: Int? = nil) {
            guard let window = view.window, let rect = view.caretRect(at: location) else { return }
            let point = view.convert(NSPoint(x: rect.midX + 1, y: rect.midY), to: nil)
            func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let dragTo, let to = view.caretRect(at: dragTo), let drag = event(.leftMouseDragged, view.convert(NSPoint(x: to.midX + 1, y: to.midY), to: nil)) { window.postEvent(drag, atStart: false) }
            if let up = event(.leftMouseUp, dragTo.flatMap { view.caretRect(at: $0) }.map { view.convert(NSPoint(x: $0.midX + 1, y: $0.midY), to: nil) } ?? point) { window.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, point) { view.mouseDown(with: down) }
        }
        view.setSelectedRange(NSRange(location: 1, length: 0))
        click(at: 8, .command)
        let added = heads()
        click(at: 8, .command)
        log.check(added == [1, 8] && view.carets == nil && view.selectedRange().location == 1, "⌘-click: a caret more there; ⌘-click on it: gone (\(added))")

        // ⌥-drag down three lines: a column of selections.
        click(at: 1, .option, dragTo: 14)
        let column = view.currentCarets.ranges
        log.check(column.count == 3 && column.allSatisfy { $0.length == 2 }, "⌥-drag: a column, a selection a line (\(column))")
        // The window in front for a moment: the system draws the other carets in the key window.
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        view.setCarets(Carets([Caret(anchor: 0, head: 5), Caret(8), Caret(12)]))
        try? await Task.sleep(for: .milliseconds(600))
        if let frame = view.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("carets.png"))
        }
        ScenarioFocus.giveBackNow()
        view.collapseCarets()
        await close(url)

        // Many carets: Find All on 2,000 matches in highlighted JavaScript, then a keystroke and
        // a delete at all of them, timed (Debug, the main thread's share).
        let js = (1...2_000).map { "let item\($0) = \"text \($0)\"; // note \($0)\n" }.joined()
        guard let manyURL = Untitled.create(text: js, name: "carets-many-\(marker).js") else { log.check(false, "a JavaScript buffer"); return }
        AppDelegate.openFile(manyURL)
        _ = await waitFor(10) { Documents.existing(for: manyURL)?.ready == true && Documents.existing(for: manyURL)?.editor.textView.window?.isVisible == true }
        guard let many = Documents.existing(for: manyURL) else {
            log.check(false, "the JavaScript buffer opened")
            try? FileManager.default.removeItem(at: manyURL.deletingLastPathComponent())   // or it comes back at the next launch
            return
        }
        let manyView = many.editor.textView
        let keyword = (js as NSString).range(of: "let").location, name = (js as NSString).range(of: "item1").location
        let colored = await waitFor(10) { drawnColor(manyView, at: keyword) != "none" && drawnColor(manyView, at: keyword) != drawnColor(manyView, at: name) }
        // (Inside the comment: the scheme draws its "//" in the text's own color, as Sublime does.)
        let commentColor = drawnColor(manyView, at: (js as NSString).range(of: "note 1\n").location)
        let manyFind = many.editor.find
        manyFind.open(replace: false)
        manyFind.query = "item"
        var started = Date()
        manyFind.findAll()
        let allTime = Date().timeIntervalSince(started)
        let count = manyView.currentCarets.count
        started = Date()
        manyView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        let keyTime = Date().timeIntervalSince(started)
        let typed = manyView.string.hasPrefix("let x1 = ") && manyView.string.contains("let x2000 = ")
        // The colors moved with the text till the next highlight: drawn from them now, the first
        // line's comment is still one, and the semicolon before it isn't.
        many.editor.render(force: true)
        let edited = manyView.string as NSString
        let comment = edited.range(of: "note 1\n").location, semicolon = edited.range(of: "; // note 1\n").location
        let movedDrawn = (drawnColor(manyView, at: comment), drawnColor(manyView, at: semicolon))
        let movedColors = commentColor != "none" && movedDrawn.0 == commentColor && movedDrawn.1 != commentColor
        started = Date()
        manyView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        let deleteTime = Date().timeIntervalSince(started)
        func ms(_ t: TimeInterval) -> String { "\(Int((t * 1000).rounded())) ms" }
        // And the tree has it all: scrolled to the end, the last line's comment is colored.
        let end = (manyView.string as NSString).length
        manyView.reveal(end)
        let last = await waitFor(5) { drawnColor(manyView, at: (manyView.string as NSString).range(of: "note 2000").location) == commentColor }
        log.check(colored && count == 2_000 && typed && manyView.string.hasPrefix("let 1 = ") && keyTime < 0.25 && deleteTime < 0.25,
                  "2,000 carets from Find All (\(ms(allTime))) in highlighted JavaScript: a keystroke at all of them \(ms(keyTime)), a delete \(ms(deleteTime)) (Debug; one pass a caret over the colors was 2.9 s)")
        log.check(movedColors && last, "the colors move with the text at every caret, and the next highlight has them all (the comment \(commentColor); after the edit \(movedDrawn.0), the semicolon \(movedDrawn.1); the last line's \(last ? "too" : "not"))")
        manyFind.query = ""
        await close(manyURL)

        /// Gone before the scenario ends: an untitled buffer still open at quit comes back at the
        /// next launch (two of these opened in the next scenarios' windows, 2026-10-01).
        func close(_ buffer: URL) async {
            Untitled.letGo(buffer)
            Documents.existing(for: buffer)?.editor.textView.window?.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: buffer) == nil }
        }
    }

    /// The minimap (ED11): on by default beside the scroller, the text beside it; each word a bar
    /// in its syntax color; the box over the lines in view, following the scroll; a click in it
    /// scrolls there, and a drag of the box scrolls with it; View › Hide Minimap gives the text
    /// its width back. Then 2 MB of JavaScript: the minimap's draw, a jump to its middle, and a
    /// keystroke, timed (Debug).
    static func minimapScenario(_ log: HarnessLog, _ marker: String) async {
        func open(_ text: String, _ name: String) async -> Document? {
            guard let url = Untitled.create(text: text, name: name) else { return nil }
            AppDelegate.openFile(url)
            _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url)
        }
        /// Closed and gone: a buffer leaves the list as its closing begins, and one still on its
        /// way out at the quit comes back at the next launch (the first runs, 2026-10-02).
        func close(_ document: Document) async {
            let url = document.url
            Untitled.letGo(url)
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
        }
        /// The editor's first and last lines in view.
        func firstLine(_ editor: Editor) -> Int {
            let view = editor.textView, origin = view.textContainerOrigin
            let at = view.characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: max(view.visibleRect.minY, origin.y) + 1))
            return editor.lineIndex.line(at: at == NSNotFound ? 0 : at)
        }
        func lastLine(_ editor: Editor) -> Int {
            let view = editor.textView, origin = view.textContainerOrigin
            let at = view.characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: view.visibleRect.maxY - 1))
            return editor.lineIndex.line(at: at == NSNotFound ? 0 : at)
        }
        let defaults = NibDefaults.store
        defer { defaults.removeObject(forKey: "editorMinimap") }

        // 3,000 lines of JavaScript, a long comment every 100th (it wraps).
        let js = (1...3_000).map { $0 % 100 == 0 ? "// \(String(repeating: "a long comment that wraps, line \($0); ", count: 10))\n" : "let item\($0) = \"text \($0)\"; // note \($0)\n" }.joined()
        guard let document = await open(js, "minimap-\(marker).js") else { log.check(false, "a JavaScript buffer opened"); return }
        let editor = document.editor, view = editor.textView
        guard let minimap = editor.minimap else { log.check(false, "a minimap, on by default"); await close(document); return }
        _ = await waitFor(10) { minimap.drawnBars > 0 && minimap.drawnColors.count >= 3 }
        let clip = editor.scrollView.contentView.frame
        log.check(!minimap.isHidden && minimap.frame.width == MinimapView.width && minimap.frame.minX >= clip.maxX - 0.5 && view.frame.width <= clip.width + 0.5,
                  "on by default, beside the scroller, the text beside it (\(Int(minimap.frame.width)) points; the text \(Int(clip.width)))")
        log.check(minimap.drawnColors.count >= 3, "each word a bar in its syntax color (\(minimap.drawnBars) bars in \(minimap.drawnColors.count) colors; drawn in \(String(format: "%.1f", minimap.drawMilliseconds)) ms)")
        let height = minimap.bounds.height
        log.check(minimap.drawnBox.minY.magnitude < 1 && firstLine(editor) == 1, "at the top, the box at the top (\(Int(minimap.drawnBox.minY))-\(Int(minimap.drawnBox.maxY)) of \(Int(height)))")

        // The text scrolled to its middle: the box in the minimap's middle.
        editor.scroll(toTop: editor.lineIndex.start(ofLine: 1_500) ?? 0)
        minimap.display()
        let middle = minimap.drawnBox.midY / height
        log.check(abs(firstLine(editor) - 1_500) <= 2 && abs(middle - 0.5) < 0.1,
                  "scrolled to line \(firstLine(editor)) of 3,000: the box follows, its middle \(Int(middle * 100))% down")

        // A click near the bottom of the minimap: the line drawn there comes to the middle of the view.
        let target = minimap.line(atY: height * 0.9) ?? 0
        minimap.simulateDrag(from: height * 0.9, to: [])
        let (top, bottom) = (firstLine(editor), lastLine(editor))
        minimap.display()
        // (The middle by rows: a wrapped line below it takes several.)
        log.check(target > 1_550 && top <= target && target <= bottom && abs((top + bottom) / 2 - target) <= max(3, (bottom - top) / 4),
                  "a click 90% down the minimap brings the line drawn there, \(target), to the middle of the view (lines \(top)-\(bottom))")
        // The box dragged up: the text goes with it.
        let box = minimap.drawnBox
        minimap.simulateDrag(from: box.midY, to: [box.midY - 40, height * 0.1])
        let dragged = firstLine(editor)
        minimap.display()
        log.check(dragged < 700 && abs(minimap.drawnBox.midY - height * 0.1) < max(40, minimap.drawnBox.height),
                  "dragging the box up scrolls the text with it (line \(dragged) at the top; the box at \(Int(minimap.drawnBox.midY)), dragged to \(Int(height * 0.1)))")
        // The box dragged to the foot and past it, the mouse moving a point or so there as a hand
        // does: the text at its end, and still (the user, 2026-10-06: at the very bottom it shook).
        let from = minimap.drawnBox.midY
        let past = (0..<24).map { height + 6 + CGFloat($0 % 3) }
        minimap.simulateDrag(from: from, to: [height * 0.5, height * 0.95] + past)
        let tops = Array(minimap.dragTops.suffix(past.count))
        let shook = zip(tops, tops.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        let foot = lastLine(editor), lines = editor.lineIndex.lineCount
        log.line("dragged past the foot: the text's top after each move there \(tops.map { Int($0.rounded()) })")
        log.check(tops.count == past.count && shook < 1 && foot >= lines - 1,
                  "dragging the box past the minimap's foot: the text at its end (line \(foot) of \(lines) in view), and still (it moved \(Int(shook.rounded())) points between moves there)")

        // View › Hide Minimap: the text has its width back; Show brings it again.
        let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        let hideItem = viewMenu?.items.first { $0.title == "Hide Minimap" }
        defaults.set(false, forKey: "editorMinimap")
        let hid = await waitFor(5) { editor.minimap == nil }
        let wider = editor.scrollView.contentView.frame.width
        defaults.set(true, forKey: "editorMinimap")
        let back = await waitFor(5) { editor.minimap != nil && !(editor.minimap?.isHidden ?? true) }
        log.check(hideItem != nil && hid && wider >= clip.width + MinimapView.width - 1 && back,
                  "View › Hide Minimap: gone, the text \(Int(wider)) points wide (from \(Int(clip.width))); Show Minimap brings it back")

        await close(document)

        // A picture of text like a podcast feed's (tags, long descriptions that wrap), to look at.
        let items = (1...40).map { n in
            """
                <item>
                  <title>Episode \(n): Notes on the work</title>
                  <description>&lt;p&gt;A paragraph about episode \(n), long enough to wrap in the editor and in the minimap, as the descriptions in a feed do. It goes on for a while, then ends.&lt;/p&gt;</description>
                  <link>https://example.com/posts/episode-\(n)/</link>
                  <guid isPermaLink="false">\(UUID().uuidString.lowercased())</guid>
                  <pubDate>Fri, \(n % 28 + 1) Sep 2026 00:00:00 GMT</pubDate>
                  <enclosure url="https://example.com/audio/episode-\(n).mp3" length="\(16_000_000 + n * 1_000)" type="audio/mpeg"/>
                </item>

            """
        }.joined()
        if let feed = await open("<!DOCTYPE html>\n<html>\n<body>\n<channel>\n" + items + "</channel>\n</body>\n</html>\n", "minimap-look-\(marker).html") {
            _ = await waitFor(10) { (feed.editor.minimap?.drawnColors.count ?? 0) >= 3 }
            feed.editor.scroll(toTop: feed.editor.lineIndex.start(ofLine: 60) ?? 0)
            try? await Task.sleep(for: .milliseconds(600))   // its colors, for what the minimap shows
            feed.editor.minimap?.display()
            if let frame = feed.editor.textView.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("minimap.png"))
            }
            await close(feed)
        }

        // 2 MB of JavaScript: the draw, a jump to the middle, a keystroke.
        let big = (1...45_000).map { "let item\($0) = \"text \($0)\"; // note \($0)\n" }.joined()
        guard let large = await open(big, "minimap-big-\(marker).js"), let bigMap = large.editor.minimap else { log.check(false, "a 2 MB buffer opened, with its minimap"); return }
        _ = await waitFor(15) { bigMap.drawnBars > 0 && bigMap.drawnColors.count >= 3 }
        var started = Date()
        bigMap.display()
        let drawn = Date().timeIntervalSince(started)
        started = Date()
        large.editor.scroll(toTop: large.editor.lineIndex.start(ofLine: 22_500) ?? 0)
        let jumped = Date().timeIntervalSince(started)
        let landed = firstLine(large.editor)
        bigMap.display()
        let bigView = large.editor.textView
        bigView.setSelectedRange(NSRange(location: large.editor.lineIndex.start(ofLine: landed + 2) ?? 0, length: 0))
        try? await Task.sleep(for: .milliseconds(500))   // the jump's layout and colors done
        // Ten keystrokes, as typed: the slowest, on the main thread (the minimap only notes each).
        var slowest = 0.0
        for character in "minimap 10" {
            started = Date()
            bigView.insertText(String(character), replacementRange: bigView.selectedRange())
            slowest = max(slowest, Date().timeIntervalSince(started))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(250))   // its redraw after the typing, the rows worked out again
        started = Date()
        bigMap.display()
        let redrawn = Date().timeIntervalSince(started)
        log.check(drawn < 0.05 && jumped < 0.5 && abs(landed - 22_500) <= 2 && slowest < 0.05 && redrawn < 0.08,
                  "\(String(format: "%.1f", Double(big.utf8.count) / 1_000_000)) MB, 45,000 lines: drawn in \(Int(drawn * 1000)) ms, a jump to its middle \(Int(jumped * 1000)) ms (line \(landed)), the slowest of ten keystrokes \(Int(slowest * 1000)) ms, drawn after them \(Int(redrawn * 1000)) ms (Debug)")
        for _ in 0..<10 { bigView.undoManager?.undo() }
        await close(large)
    }

    /// ED10, as in Sublime: closing pairs as typed (an opener closed before a space or the line's
    /// end, not before a word; a quote not after a letter; a closer stepped over; Backspace taking
    /// an empty pair; Return between braces opening an indented line; a selection wrapped); the
    /// brackets at the caret underlined, beside it or round it; an HTML element's tag names;
    /// indent guides; and each off in Settings › Editor.
    static func pairsScenario(_ log: HarnessLog, _ marker: String) async {
        let defaults = NibDefaults.store
        defaults.set(true, forKey: "editorAutoPairs")   // off for the other scenarios' typing
        defer { for key in ["editorAutoPairs", "editorIndentGuides", "editorMatchBrackets"] { defaults.removeObject(forKey: key) } }
        func open(_ text: String, _ name: String) async -> Document? {
            guard let url = Untitled.create(text: text, name: name) else { return nil }
            AppDelegate.openFile(url)
            _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url)
        }
        func close(_ document: Document) async {
            let url = document.url
            Untitled.letGo(url)
            _ = await waitFor(5) { document.editor.textView.window?.attachedSheet == nil }
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
        }
        let start = "function f() {\n    if (x) {\n        y();\n    }\n}\n"
        guard let js = await open(start, "pairs-\(marker).js") else { log.check(false, "a JavaScript buffer"); return }
        let view = js.editor.textView
        _ = await waitFor(3) { view.autoPairs }
        func type(_ s: String) { for c in s { view.insertText(String(c), replacementRange: NSRange(location: NSNotFound, length: 0)) } }
        func tail(_ count: Int) -> String { String(view.string.suffix(count)) }
        func caretFromEnd() -> Int { (view.string as NSString).length - view.selectedRange().location }
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        type("call(")
        let opened = tail(6) == "call()" && caretFromEnd() == 1
        type("a)")
        log.check(opened && tail(7) == "call(a)" && caretFromEnd() == 0, "( closes itself before the line's end, and ) steps over the one already there (\(tail(7).debugDescription))")
        type(" [")
        let bracket = tail(3) == " []"
        view.deleteBackward(nil)
        log.check(bracket && tail(8) == "call(a) " && caretFromEnd() == 0, "Backspace between an empty pair takes both (\(tail(8).debugDescription))")
        type("x = don't + b")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))   // before the b
        type("(")
        log.check(tail(14) == "x = don't + (b", "no pair for an apostrophe after a letter, or for ( before a word (\(tail(14).debugDescription))")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        type("\nwhile (z) {")
        view.insertNewline(nil)
        let opening = tail(18) == "while (z) {\n    \n}" && caretFromEnd() == 2
        log.check(opening, "Return between braces: a line between, a step in, the closer under (\(tail(18).debugDescription), the caret \(caretFromEnd()) from the end)")
        let word = (view.string as NSString).range(of: "don't")
        view.setSelectedRange(word)
        type("\"")
        log.check(view.string.contains("\"don't\"") && view.selectedRange() == NSRange(location: word.location + 1, length: word.length), "a selection is wrapped, and still selected inside")

        // The brackets at the caret.
        let ns = view.string as NSString
        let call = ns.range(of: "call(a)")
        view.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
        let beside = view.matchedBrackets
        let y = ns.range(of: "y();")
        view.setSelectedRange(NSRange(location: y.location, length: 0))
        let inside = view.matchedBrackets
        let ifBrace = ns.range(of: "if (x) {").location + 7, ifClose = ns.range(of: "    }\n}").location + 4
        log.check(beside == Brackets.Match(open: call.location + 4, close: NSMaxRange(call) - 1, beside: true)
                  && inside == Brackets.Match(open: ifBrace, close: ifClose, beside: false),
                  "the brackets beside the caret matched, and with none beside it the pair round it (\(beside.map { "\($0.open)-\($0.close)" } ?? "none"), \(inside.map { "\($0.open)-\($0.close) inside" } ?? "none"))")
        view.display()
        let underlined = view.underlinesDrawn, guides = view.guidesDrawn
        log.check(underlined == 2 && guides >= 4, "drawn: both brackets underlined, and the indent guides (\(underlined) underlines, \(guides) guides)")
        // A picture, to look at: the caret after call(a)'s ), its pair underlined.
        view.setSelectedRange(NSRange(location: NSMaxRange(call), length: 0))
        if let frame = view.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("pairs.png"))
        }

        // Each off in Settings › Editor.
        defaults.set(false, forKey: "editorIndentGuides")
        defaults.set(false, forKey: "editorMatchBrackets")
        defaults.set(false, forKey: "editorAutoPairs")
        _ = await waitFor(3) { !view.autoPairs && !view.showsIndentGuides && !view.matchBrackets }
        view.display()
        let before = view.string
        view.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
        type("(")
        log.check(view.guidesDrawn == 0 && view.matchedBrackets == nil && view.string == before + "(",
                  "Settings › Editor turns each off: no guides, nothing underlined, ( only typed")
        await close(js)

        // An HTML element's tags, with the caret inside it.
        defaults.removeObject(forKey: "editorMatchBrackets")
        guard let html = await open("<div class=\"note\">\n  <p>Some text \(marker)</p>\n</div>\n", "pairs-\(marker).html") else { return }
        let hview = html.editor.textView, hs = hview.string as NSString
        _ = await waitFor(5) { hview.matchBrackets }
        try? await Task.sleep(for: .milliseconds(500))   // the tree made
        hview.setSelectedRange(NSRange(location: hs.range(of: "Some").location + 2, length: 0))
        let p = hs.range(of: "<p>").location + 1, pEnd = hs.range(of: "</p>").location + 2
        let tagged = await waitFor(5) { hview.matchedTags == [NSRange(location: p, length: 1), NSRange(location: pEnd, length: 1)] }
        hview.display()
        log.check(tagged && hview.underlinesDrawn == 2, "in HTML, the element round the caret: <p> and </p> underlined, stippled (\(hview.matchedTags.map { "\(hs.substring(with: $0))@\($0.location)" }))")
        await close(html)

        // In XML too (HL8): inside a self-closing element, the element round it, namespace and all.
        guard let feed = await open("<rss>\n  <itunes:category text=\"Technology\">\n    <itunes:category text=\"Software\"/>\n  </itunes:category>\n</rss>\n", "pairs-\(marker).xml") else { return }
        let fview = feed.editor.textView, fs = fview.string as NSString
        _ = await waitFor(5) { fview.matchBrackets }
        try? await Task.sleep(for: .milliseconds(500))   // the tree made
        fview.setSelectedRange(NSRange(location: fs.range(of: "Software").location + 2, length: 0))
        let name = ("itunes:category" as NSString).length
        let startTag = fs.range(of: "itunes:category").location, endTag = fs.range(of: "</itunes:category>").location + 2
        let xmlTagged = await waitFor(5) { fview.matchedTags == [NSRange(location: startTag, length: name), NSRange(location: endTag, length: name)] }
        fview.display()
        log.check(feed.syntaxName == "XML" && xmlTagged && fview.underlinesDrawn == 2,
                  "in XML, inside a self-closing element: the element round it, both itunes:category names underlined (\(fview.matchedTags.map { "\(fs.substring(with: $0))@\($0.location)" }))")
        await close(feed)
    }

    /// Go to Heading (SC7, ⌘R): a Markdown file's headings in order, from the caret's section,
    /// filtered as typed; one chosen puts the caret there and the heading near the top. A
    /// JavaScript file has none; a 2.4 MB file's come without holding up the main thread.
    static func headingsScenario(_ log: HarnessLog, _ marker: String) async {
        func open(_ text: String, _ name: String) async -> Document? {
            guard let url = Untitled.create(text: text, name: name) else { return nil }
            AppDelegate.openFile(url)
            _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url)
        }
        func close(_ document: Document) async {
            let url = document.url
            Untitled.letGo(url)
            _ = await waitFor(5) { document.editor.textView.window?.attachedSheet == nil }   // a window with a sheet doesn't close
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
        }
        func firstLine(_ document: Document) -> Int {
            let view = document.editor.textView, origin = view.textContainerOrigin
            let at = view.characterIndexForInsertion(at: NSPoint(x: origin.x + 1, y: max(view.visibleRect.minY, origin.y) + 1))
            return document.editor.lineIndex.line(at: at == NSNotFound ? 0 : at)
        }
        let textMenu = NSApp.mainMenu?.items.first { $0.title == "Text" }?.submenu
        let item = textMenu?.items.first { $0.title == "Go to Heading…" }
        log.check(item?.keyEquivalent == "r" && item?.keyEquivalentModifierMask == .command, "Text › Go to Heading…, ⌘R")

        let body = (1...40).map { "Line \($0) of the section, \(marker).\n" }.joined()
        let text = "# Notes \(marker)\n\n" + body + "## Week one\n\n" + body + "```bash\n# not a heading\n```\n\n### Monday\n\n" + body
            + "\nWeek two\n--------\n\n" + body + "## Week three\n\n" + body + body + body   // room below it, to come to the top
        guard let document = await open(text, "headings-\(marker).md") else { log.check(false, "a Markdown buffer opened"); return }
        let ns = text as NSString
        document.editor.textView.setSelectedRange(NSRange(location: ns.range(of: "### Monday").location + 20, length: 0))   // in Monday's section
        AppDelegate.showPalette(.headings, in: document)
        _ = await waitFor(5) { (document.palette?.entries.count ?? 0) > 0 }
        guard let session = document.palette else { log.check(false, "the headings came up"); await close(document); return }
        let listed = session.entries.map { "\($0.group) \($0.name)" }
        let monday = session.entries.first { $0.name == "Monday" }
        log.check(listed == ["# Notes \(marker)", "## Week one", "### Monday", "## Week two", "## Week three"] && session.prompt == "Go to a heading",
                  "the headings in order, at their levels, not the comment in code (\(listed.joined(separator: " · ")))")
        log.check(session.initial == monday?.id && monday?.detail == "Line \(document.editor.lineIndex.line(at: ns.range(of: "### Monday").location))",
                  "the list starts on the caret's section, Monday, with its line (\(monday?.detail ?? "none"))")
        let filtered = CommandPalette.results(for: "week t", in: session.entries).map(\.name)
        log.check(filtered.prefix(2) == ["Week two", "Week three"], "typing filters them, as in Go to File (\(filtered.joined(separator: ", ")))")
        // Week three chosen: the caret there, the heading near the top.
        if let three = session.entries.first(where: { $0.name == "Week three" }) {
            session.choose(three)
            document.palette = nil
            let target = ns.range(of: "## Week three").location, line = document.editor.lineIndex.line(at: target)
            let went = await waitFor(5) { document.editor.textView.selectedRange().location == target }
            try? await Task.sleep(for: .milliseconds(300))
            // (Two lines above it in sight, give or take the part of a line the scroll stops at.)
            log.check(went && abs(firstLine(document) - (line - 2)) <= 1, "choosing one puts the caret at it, the heading near the top (line \(firstLine(document)) at the top, the heading at \(line))")
        }
        _ = await waitFor(3) { document.palette == nil }
        // Coming up doesn't hold the main thread (a list filled after the sheet came up did, 0.3 s).
        _ = await waitFor(5) { document.editor.textView.window?.attachedSheet == nil }
        try? await Task.sleep(for: .milliseconds(300))
        let watch = StallWatch()
        watch.start()
        AppDelegate.showPalette(.headings, in: document)
        _ = await waitFor(5) { (document.palette?.entries.count ?? 0) > 0 }
        try? await Task.sleep(for: .milliseconds(300))
        watch.stop()
        document.palette = nil
        _ = await waitFor(5) { document.editor.textView.window?.attachedSheet == nil }
        try? await Task.sleep(for: .milliseconds(300))
        let files = StallWatch()
        files.start()
        AppDelegate.showPalette(.files, in: document)
        try? await Task.sleep(for: .milliseconds(600))
        files.stop()
        // Against Go to File's: the palette's sheet itself holds the main thread a while (Debug).
        let paletteCost = files.longest
        log.check(watch.longest <= max(0.15, paletteCost * 1.3 + 0.05),
                  "it comes up as quickly as Go to File (its longest wait \(Int(watch.longest * 1000)) ms, Go to File's \(Int(paletteCost * 1000)) ms, Debug)")
        document.palette = nil
        await close(document)

        // A JavaScript file: none, and the list says why.
        if let script = await open("// Go to Heading in a script \(marker)\nfunction f() {}\n", "headings-\(marker).js") {
            AppDelegate.showPalette(.headings, in: script)
            _ = await waitFor(3) { script.palette != nil }
            log.check(script.palette?.entries.isEmpty == true && script.palette?.empty == "Go to Heading lists a Markdown file's headings, and this file isn't Markdown",
                      "a JavaScript file: no headings, and the list says why (\(script.palette?.empty ?? "no palette"))")
            script.palette = nil
            _ = await waitFor(3) { script.palette == nil }
            await close(script)
        }

        // 2.4 MB, a heading every 100 lines: found off the main thread.
        var big = "# Big \(marker)\n"
        for n in 1...35_000 { big += n % 100 == 0 ? "## Section \(n)\n" : "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
        if let large = await open(big, "headings-big-\(marker).md") {
            try? await Task.sleep(for: .seconds(2))   // its opening's own work done: colors, the minimap
            var times: [(took: Double, longest: Double, came: Bool)] = []
            for _ in 0..<2 {   // the second time, the palette's sheet is made a second time too
                let watch = StallWatch()
                watch.start()
                let asked = Date()
                AppDelegate.showPalette(.headings, in: large)
                let came = await waitFor(10) { (large.palette?.entries.count ?? 0) == 351 }
                let took = Date().timeIntervalSince(asked)
                try? await Task.sleep(for: .milliseconds(300))
                watch.stop()
                times.append((took, watch.longest, came))
                large.palette = nil
                _ = await waitFor(5) { large.editor.textView.window?.attachedSheet == nil }
                try? await Task.sleep(for: .milliseconds(300))
            }
            log.check(times.allSatisfy { $0.came && $0.longest <= max(0.15, paletteCost * 1.3 + 0.05) },
                      "2.4 MB, 351 headings: listed in \(times.map { "\(Int($0.took * 1000)) ms" }.joined(separator: " and ")), found off the main thread: its longest wait \(times.map { "\(Int($0.longest * 1000)) ms" }.joined(separator: " and ")), as the palette's own (Debug)")
            await close(large)
        }
    }

    /// A scroll to a stretch taller than the view, then typing: TextKit 2 kept the stretch to scroll
    /// to and used it after the edits had changed the text under it, and crashed (the `mdlist`
    /// scenario's first runs, 2026-10-02: `__NSTextViewScrollContainerViewToTextRange`).
    static func wideScrollScenario(_ log: HarnessLog, _ marker: String) async {
        // Markdown with bold and italic: their faces are attributes on the text storage, set as it
        // colors, which TextKit 2 takes as a change to the paragraphs under a kept stretch.
        let lines = NibDefaults.store.bool(forKey: "NibWideScrollBig") ? 40_000 : 3_000
        let text = (1...lines).map { $0 % 3 == 0 ? "- item \($0) with `code` and **bold** text\n" : "Line \($0): see https://example.com/\($0) and _the_ config.json file.\n" }.joined()
        guard let url = Untitled.create(text: text, name: "widescroll-\(marker).md") else { log.check(false, "a buffer"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "it opened"); return }
        let editor = document.editor, view = editor.textView
        let start = editor.lineIndex.start(ofLine: 1_000) ?? 0, end = editor.lineIndex.start(ofLine: 1_300) ?? 0
        let how = NibDefaults.store.string(forKey: "NibWideScrollHow") ?? "nib"
        if how == "appkit" { view.scrollRangeToVisible(NSRange(location: start, length: end - start)) }
        else { editor.reveal(NSRange(location: start, length: end - start)) }
        try? await Task.sleep(for: .milliseconds(500))
        view.setSelectedRange(NSRange(location: start, length: 0))
        for character in "typed after a tall scroll " {
            view.insertText(String(character), replacementRange: view.selectedRange())
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(500))
        log.check(view.string.contains("typed after a tall scroll"), "typing after a scroll to 300 lines, taller than the view (\(how)): still here")
        Untitled.letGo(url)
        view.window?.performClose(nil)
        _ = await waitFor(10) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
    }

    /// A numbered list made in Markdown as the user made one (2026-10-02): title lines first,
    /// then "1. ", "2. "… typed at the start of each, key by key, in a 2.4 MB file (a tree of the
    /// stretch round the view), the list near line 4,383. Every item is one list item, marker and
    /// text in the scheme's `markup.list` color, in the colors TextKit holds and on the screen.
    static func markdownListScenario(_ log: HarnessLog, _ marker: String) async {
        let titles = ["Creative Production: Knowing Which Ideas to Cut", "Why Smart Teams Struggle to Decide",
                      "Creative Reviews: Judge the Work, Not the Intention", "Client Feedback: Hearing the Anxiety Behind the Notes",
                      "Creative Decisions: Make a Recommendation and Commit", "When the Project Changes, Revisit the Plan",
                      "What Producers Do: Translate Between Clients and Creative Teams", "Production Risk: Which Mistakes Can the Project Survive?"]
        var text = "# Notes \(marker)\n", n = 0
        while text.utf8.count < 2_400_000 {
            n += 1
            if n == 4_380 {
                text += "\n" + (1...17).map { "\(titles[($0 - 1) % titles.count]) | The Show Ep. \($0)\n" }.joined() + "\n"
                continue
            }
            switch n % 200 {
            case 0: text += "```bash\nrsync -av --progress ./dist/ me@seedbox:~/www/ && echo \"done \(n)\"\n```\n"
            case 50: text += "## Notes for \(n)\n"
            default:
                if n % 25 == 0 { text += String(repeating: "A long paragraph that wraps, about item \(n), ", count: 5) + "\n" }
                else if n % 3 == 0 { text += "- item \(n) with `code` and **bold** text\n" }
                else { text += "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
            }
        }
        guard let url = Untitled.create(text: text, name: "mdlist-\(marker).md") else { log.check(false, "a Markdown buffer"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "it opened"); return }
        defer { Untitled.letGo(url) }
        let editor = document.editor, view = editor.textView
        let ns = text as NSString
        let first = ns.range(of: titles[0]).location
        let firstLine = editor.lineIndex.line(at: first)
        view.setSelectedRange(NSRange(location: first, length: 0))
        editor.scroll(toTop: max(0, first - 1))   // the whole list in view, as typed (a scroll to 2,000 characters crashed TextKit: `widescroll`)
        try? await Task.sleep(for: .seconds(1))   // colors for the stretch in view
        for item in 1...17 {
            guard let start = editor.lineIndex.start(ofLine: firstLine + item - 1) else { break }
            view.setSelectedRange(NSRange(location: start, length: 0))
            for character in "\(item). " {
                view.insertText(String(character), replacementRange: view.selectedRange())
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .seconds(1.5))   // the last highlight in
        let orange = "#EF7C2B"
        var wrong: [String] = []
        for item in 1...17 {
            guard let start = editor.lineIndex.start(ofLine: firstLine + item - 1) else { continue }
            let markerColor = drawnColor(view, at: start), textColor = drawnColor(view, at: start + 6)
            if markerColor != orange || textColor != orange { wrong.append("\(item): \(markerColor)/\(textColor)") }
        }
        log.check(wrong.isEmpty, "a numbered list typed in front of title lines in a 2.4 MB file: every item in the list color, marker and text (\(wrong.isEmpty ? "all 17" : "wrong: " + wrong.joined(separator: ", ")))")
        // And on the screen. TextKit 2 draws each stretch of text in a view of its own and draws it
        // again only when its text changes: a change of colors left the user's list (2026-10-02) in
        // the colors each line had when last typed on. A render must have each line's view drawn again.
        view.displayIfNeeded()
        editor.render(force: true)
        var undrawn: [Int] = []
        for item in 1...17 {
            guard let start = editor.lineIndex.start(ofLine: firstLine + item - 1), let glyph = view.caretRect(at: start + 4) else { continue }
            let point = NSPoint(x: glyph.midX, y: glyph.midY)
            let views = view.subviews.flatMap(\.subviews).filter { $0.convert($0.bounds, to: view).contains(point) }
            // (The view ignores its own `needsDisplay`; its layer holds the drawing.)
            if views.isEmpty || !views.allSatisfy({ $0.layer?.sublayers?.contains { $0.needsDisplay() } ?? false }) { undrawn.append(item) }
        }
        log.check(undrawn.isEmpty, "and on the screen: new colors have each line's view drawn again (\(undrawn.isEmpty ? "all 17" : "not: " + undrawn.map(String.init).joined(separator: ", ")))")
        // What's on the screen (the view drawn again into a picture), to look at.
        if let frame = view.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("mdlist.png"))
        }
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
    }

    /// VoiceOver (AX1, AX2): the strip's summary; its indentation, encoding and line endings in words; a notice said as a sentence;
    /// a conflict's notice said at once, the Conflicts rotor naming the block without its dot,
    /// and "No conflicts left" once it's resolved; the HUD line said too.
    static func accessScenario(_ log: HarnessLog, _ marker: String) async {
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("access-\(marker).md")
        try? Data("# Access \(marker)\n\nline three\n".utf8).write(to: url)
        defer {
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(url)
        }
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url), document.editor.textView.window != nil else { log.check(false, "the file opened"); return }
        let view = document.editor.textView
        view.setSelectedRange(NSRange(location: ("# Access \(marker)\n\nli" as NSString).length, length: 0))
        _ = await waitFor(3) { document.cursor.line == 3 }

        // The strip: one summary. (Whether VoiceOver finds it on the strip isn't checked here:
        // SwiftUI makes its accessibility tree only when an assistive app asks, and in the
        // scenario the window's hosting view has no accessibility children at all.)
        let summary = StatusStrip.summary(document)
        log.check(summary == "access-\(marker).md, \(StatusStrip.spokenState(document)), line 3, column 3, Markdown" && !summary.contains("·"),
                  "the strip reads as one summary: “\(summary)”")
        let details = StatusStrip.spokenDetails(document)
        log.check(details == "\(document.indentationLabel.lowercased()), UTF-8, LF line endings", "its indentation, encoding and line endings in words: “\(details)”")

        // A notice, said as a sentence.
        document.show("✓ MERGED 2 CHANGES FROM AIR · ⌘Z UNDOES", for: 3)
        log.check(Announce.said.last == "Merged 2 changes from air, Command-Z undoes" && StatusStrip.spokenState(document) == "merged 2 changes from air, Command-Z undoes",
                  "a notice is said, as a sentence: “\(Announce.said.last ?? "nothing")”")

        // A conflict: its notice at once, the rotor's words, and when it's gone.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("<<<<<<< Air · 10:00\nours \(marker)\n=======\ntheirs\n>>>>>>> Mini · 10:01\n", replacementRange: view.selectedRange())
        _ = await waitFor(5) { document.blocks.count == 1 }
        document.show("✕ CONFLICT WITH AIR · 1 PLACE · BOTH VERSIONS ARE IN THE TEXT", for: 3)
        log.check(Announce.said.last == "Conflict with air, 1 place, both versions are in the text", "a conflict's notice is said: “\(Announce.said.last ?? "nothing")”")
        let rotor = view.accessibilityCustomRotors().first { $0.label == "Conflicts" }
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = .next
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let item = rotor.flatMap { view.rotor($0, resultFor: parameters) }
        log.check(item?.customLabel == "Conflict: Air, 10:00, or Mini, 10:01", "the Conflicts rotor names the block: “\(item?.customLabel ?? "none")”")
        // A second block: coming into one says what it is; its actions resolve it, said with what's
        // left (the QA review's F60: the drawn words, the ✕ and resolving went unsaid).
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("<<<<<<< Air · 10:02\nmore ours \(marker)\n=======\nmore theirs\n>>>>>>> Mini · 10:03\n", replacementRange: view.selectedRange())
        _ = await waitFor(5) { document.blocks.count == 2 }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        _ = await waitFor(2) { document.activeCaretBlock == nil }
        if let block = document.blocks.first { view.setSelectedRange(NSRange(location: block.range.location + 2, length: 0)) }
        _ = await waitFor(2) { document.activeCaretBlock != nil }
        let entered = Announce.said.last ?? ""
        log.check(entered == "Conflict: Air, 10:00, or Mini, 10:01. Command-1 or Command-2 uses one, Command-3 keeps both.",
                  "coming into a block is said: “\(entered)”")
        let actions = (view.accessibilityCustomActions() ?? []).map(\.name)
        log.check(actions.contains("Use Air's version, Command-1") && actions.contains("Use Mini's version, Command-2") && actions.contains("Keep both versions, Command-3"),
                  "in it, VoiceOver's actions: \(actions.joined(separator: "; "))")
        _ = view.accessibilityCustomActions()?.first { $0.name.hasPrefix("Keep both") }?.handler?()
        _ = await waitFor(5) { document.blocks.count == 1 }
        log.check(document.blocks.count == 1 && Announce.said.last == "Kept both versions. 1 conflict left.", "Keep Both, as an action, said: “\(Announce.said.last ?? "nothing")”")
        if let block = document.blocks.first { view.setSelectedRange(NSRange(location: block.range.location + 2, length: 0)) }
        _ = await waitFor(2) { document.activeCaretBlock != nil }
        document.resolveBlock(.both)
        _ = await waitFor(5) { document.blocks.isEmpty }
        log.check(Announce.said.last == "No conflicts left in access-\(marker).md.", "resolved: “\(Announce.said.last ?? "nothing")”")

        // The HUD line, with no window of Nib's in front.
        Toast.show("CLIPBOARD CLEANED · 3 INVISIBLES REMOVED")
        log.check(Announce.said.last == "Clipboard cleaned, 3 invisibles removed", "the HUD line is said too: “\(Announce.said.last ?? "nothing")”")
    }

    /// The clipboard jobs (PT3-PT5, SC5, SC6): Paste Clean, an HTML-only clipboard pasted as
    /// text, Clean Clipboard in place, Copy Block (fenced code, a paragraph), and Append
    /// Clipboard to Scratch without moving the caret. The clipboard is put back after.
    static func cleanText(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }
        let view = document.editor.textView
        func end() { view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0)) }
        func put(_ text: String) { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }

        // Copy, read by another app (`pbpaste`, its own process): the selection's text, by the text
        // view's copy and by Edit › Copy as ⌘C sends it (the user's report, 2026-10-07: copying from
        // Nib into another app didn't seem to work).
        func otherApp() async -> String {
            await Task.detached {
                let process = Process(), out = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
                process.standardOutput = out
                try? process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return String(data: data, encoding: .utf8) ?? ""
            }.value
        }
        end()
        view.insertText("\ncopy me \(marker)\n", replacementRange: view.selectedRange())
        await endOfEvent(view)   // its own undo step, apart from the cut's below
        let copyRange = (view.string as NSString).range(of: "copy me \(marker)")
        put("before the copy")
        view.setSelectedRange(copyRange)
        view.copy(nil)
        let inNib = pasteboard.string(forType: .string) ?? "nothing"
        let byView = await otherApp()
        put("before the copy")
        view.setSelectedRange(copyRange)
        view.window?.makeFirstResponder(view)
        var byMenu = "not tried"
        // (The menu sends Copy to the window in front's text: only while Nib is in front.)
        if NSApp.isActive, let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu, let index = edit.items.firstIndex(where: { $0.title == "Copy" }) {
            edit.update()
            edit.performActionForItem(at: index)
            byMenu = await otherApp()
        }
        log.check(byView == "copy me \(marker)" && (byMenu == "copy me \(marker)" || byMenu == "not tried"),
                  "copied, another app reads the selection: by the text view “\(byView)” (in Rune “\(inNib)”), by Edit › Copy “\(byMenu)” (types \(pasteboard.types?.map(\.rawValue) ?? []))")
        // Cut too: the text in the other app, gone from Nib, and ⌘Z puts it back.
        let textBefore = view.string
        view.setSelectedRange(copyRange)
        await endOfEvent(view)
        view.cut(nil)
        let cutRead = await otherApp()
        let gone = !view.string.contains("copy me \(marker)")
        view.undoManager?.undo()
        await endOfEvent(view)
        log.check(cutRead == "copy me \(marker)" && gone && view.string == textBefore,
                  "cut: another app reads it (“\(cutRead)”), it's gone from the text (\(gone)), and ⌘Z puts it back (\(view.string == textBefore))")

        // Paste Clean.
        end()
        view.insertText("\n", replacementRange: view.selectedRange())
        let before = (view.string as NSString).length
        put("clean\u{200B}ed\u{00A0}paste \(marker)  \n")
        view.pasteAsPlainText(nil)
        let pasted = (view.string as NSString).substring(from: before)
        log.check(pasted == "cleaned paste \(marker)\n" && document.notice == "PASTED CLEAN · 1 INVISIBLE REMOVED · 1 SPACE MADE PLAIN · 1 LINE TRIMMED",
                  "Paste Clean: \(pasted.debugDescription) · \(document.notice ?? "no notice")")

        // HTML only (PT5): ⌘V pastes its text.
        pasteboard.clearContents()
        pasteboard.setString("<p><b>Bold</b> and <i>html</i> \(marker)</p>", forType: .html)
        end()
        let htmlAt = (view.string as NSString).length
        view.paste(nil)
        let html = (view.string as NSString).substring(from: htmlAt)
        log.check(html.hasPrefix("Bold and html \(marker)"), "an HTML-only clipboard pastes as its text: \(html.debugDescription)")

        // Clean Clipboard, in place.
        let rich = NSAttributedString(string: "tab\u{FEFF}le\u{2009}row  ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        pasteboard.clearContents()
        pasteboard.writeObjects([rich])
        AppDelegate.cleanClipboard()
        let types = Set(pasteboard.types?.map(\.rawValue) ?? [])
        log.check(pasteboard.string(forType: .string) == "table row" && types.isSubset(of: [NSPasteboard.PasteboardType.string.rawValue, "NSStringPboardType"])
                  && Toast.last == "CLIPBOARD CLEANED · 1 INVISIBLE REMOVED · 1 SPACE MADE PLAIN · 1 LINE TRIMMED · FORMATTING DROPPED",
                  "Clean Clipboard: plain text only, cleaned (\(Toast.last ?? "no confirmation"))")
        if let content = Toast.window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-toast.png"))
        }

        // Copy Block: the fenced code at the caret, then a paragraph.
        end()
        view.insertText("\n```bash\necho one \(marker)\necho two\n```\n\nA paragraph \(marker)\nthat wraps.\n", replacementRange: view.selectedRange())
        let text = view.string as NSString
        view.setSelectedRange(NSRange(location: text.range(of: "echo two", options: .backwards).location, length: 0))   // this run's (the file keeps earlier ones)
        view.copyBlock(nil)
        let code = pasteboard.string(forType: .string)
        log.check(code == "echo one \(marker)\necho two" && document.notice == "COPIED THE CODE BLOCK · 2 LINES",
                  "Copy Block in a fence: its code, without the fences (\(document.notice ?? "no notice"))")
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "that wraps", options: .backwards).location, length: 0))
        view.copyBlock(nil)
        log.check(pasteboard.string(forType: .string) == "A paragraph \(marker)\nthat wraps.", "and in a paragraph: the paragraph (\(document.notice ?? "no notice"))")

        // Append Clipboard to Scratch: at the end after a blank line; the caret stays.
        put("appended line \(marker)\n")
        let caret = NSRange(location: 3, length: 0)
        view.setSelectedRange(caret)
        AppDelegate.appendClipboard()
        log.check(view.string.hasSuffix("that wraps.\n\nappended line \(marker)\n") && view.selectedRange() == caret
                  && document.notice == "APPENDED 1 LINE TO SCRATCH",
                  "Append Clipboard to Scratch: after a blank line at the end, the caret where it was (\(document.notice ?? "no notice"))")
        let saved2 = await waitFor(10) { fileText(document).contains("appended line \(marker)") }
        log.check(saved2, "and saved like any edit")
        // The Edit menu has them.
        let edit = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.filter { !$0.isHidden }.map(\.title) ?? []
        log.check(["Copy Block", "Paste Clean", "Clean Clipboard", "Append Clipboard to Scratch"].allSatisfy(edit.contains) && !edit.contains("Paste and Match Style"),
                  "the Edit menu: \(edit.filter { !$0.isEmpty }.joined(separator: ", "))")
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

    /// §4.3, §4.9 row 24: typing in a big text journals the change, not the text. A 2.4 MB
    /// untitled buffer, saving held off as for `crash`: at the first pause, a snapshot of it all;
    /// at each pause after, a line on the snapshot's log; then a crash, for `recover-big`.
    static func crashBig(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        var md = "# Big journal \(marker)\n", m = 0
        while md.utf8.count < 2_400_000 {
            m += 1
            md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
        }
        guard let url = Untitled.create(text: md, name: "journal-\(marker).md") else { log.check(false, "a 2.4 MB untitled buffer"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(20) { Documents.existing(for: url)?.ready == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "a 2.4 MB untitled buffer opened"); return }
        let view = document.editor.textView
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        let snapshot = journal.url(for: url.path)
        func size(_ file: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0 }
        // The log's lines, not its file's size: it keeps room ahead of them (2026-10-02).
        func logged() -> Int { journal.logBytes(for: url.path) }
        func changed(_ file: URL) -> Date? { try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date }
        await type("\n- big one \(marker)\n", into: document)
        let begun = await waitFor(5) { logged() > 0 }
        let snapshotAt = changed(snapshot), logBefore = logged()
        log.check(begun && size(snapshot) > 2_400_000, "the first pause: a snapshot of the whole text (\(size(snapshot) / 1000) KB), and its log begun")
        for n in 2...6 {
            await type("- big \(n) \(marker)\n", into: document)
            try? await Task.sleep(for: .milliseconds(400))
        }
        // A keystroke to the journal, timed: the log grows.
        let before = logged()
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        let journaled = await timed(5) { logged() > before }
        log.line("MEASURED a keystroke to the journal at 2.4 MB: \(journaled.map { "\(Int($0 * 1000)) ms" } ?? "not within 5 s") · target ≤ 300 ms · \((journaled ?? 1) <= 0.3 ? "met" : "NOT MET")")
        let appended = logged() - logBefore
        let entry = journal.read(path: url.path)
        log.check(entry?.text.hasSuffix("- big 6 \(marker)\n!") == true && changed(snapshot) == snapshotAt && appended < 4_000,
                  "six more pauses: the journal has the typing, the snapshot as it was, \(appended) bytes added to its log")
        // Saving is held off, but a window losing focus saves (as one opening can, then giving
        // the focus back): what matters is that only the journal has the last of the typing.
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        log.check(!onDisk.hasSuffix("- big 6 \(marker)\n!"),
                  "the file hasn't the last of it (\(onDisk.contains("big one \(marker)") ? "a save on losing focus took some" : "nothing saved"), saving held off for this test)")
        log.line("SIGKILL")
        kill(getpid(), SIGKILL)
    }

    /// The launch after `crash-big`: the 2.4 MB buffer comes back with all its typing, its
    /// journal's snapshot and log put together, and is saved.
    static func recoverBig(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let name = "journal-\(marker).md"
        func found() -> Document? { Documents.all.first { $0.url.lastPathComponent == name } }
        _ = await waitFor(20) { found()?.ready == true }
        guard let document = found() else {
            log.check(false, "the 2.4 MB untitled buffer came back")
            for url in Untitled.all() where url.lastPathComponent == name { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return
        }
        let text = document.editor.textView.string
        log.check(text.hasPrefix("# Big journal \(marker)\n") && text.contains("- big one \(marker)\n") && text.hasSuffix("- big 6 \(marker)\n!"),
                  "the buffer has the typing from before the crash (\((text as NSString).length / 1000)K characters)")
        log.check(document.notice?.contains("RECOVERED") == true, "the strip says so: \(document.notice ?? "nothing")")
        let saved = await waitFor(20) { (try? String(contentsOf: document.url, encoding: .utf8))?.hasSuffix("- big 6 \(marker)\n!") == true }
        log.check(saved, "and it's saved")
        // Gone before the scenario ends: an untitled buffer still open at quit comes back at the next launch.
        Untitled.letGo(document.url)
        document.editor.textView.window?.performClose(nil)
        _ = await waitFor(10) { Documents.existing(for: document.url) == nil }
    }

    /// A crash after resolving a block that's still in the file: the file has the block, the
    /// journal has the text without it, from the same base. Recovering that journal once left
    /// the file's block drawn over the shorter text, and every launch crashed or hung.
    static func crashWithBlocks(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let view = document.editor.textView
        let block = "<<<<<<< Scenario A · 10:00\n- ours \(marker)\n=======\n- theirs \(marker)\n>>>>>>> Scenario B · 10:00\n"
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("\n" + block, replacementRange: view.selectedRange())
        await endOfEvent(view)
        await document.flush(reason: "test")
        log.check(ConflictText.hasMarkers(fileText(document)) && ours(document, marker).count == 1, "a block, saved into the file")
        guard let found = ours(document, marker).first else { return }
        view.setSelectedRange(NSRange(location: found.first.location, length: 0))
        let atBlock = await waitFor(5) { document.caretBlock != nil }
        document.resolveBlock(.both)
        await endOfEvent(view)
        // The journal waited for, not a fixed 600 ms: on a busy Mac it came later, and this
        // scenario's SIGKILL then left its block in the test file for every block scenario after
        // it to trip on (two suites, 2026-10-01).
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        let both = "- ours \(marker)\n- theirs \(marker)\n"
        let journaled = await waitFor(5) { journal.read(path: document.url.path)?.text.contains(both) == true }
        let left = ours(document, marker).count, inFile = fileText(document).contains("- ours \(marker)\n=======")
        log.check(atBlock && left == 0 && journaled && inFile,
                  "Keep Both in the buffer and the journal; the file still has the block (saving held off) (at the block \(atBlock), \(left) left, journaled \(journaled), in the file \(inFile); \(document.blocks.count) blocks in all)")
        log.line("SIGKILL")
        kill(getpid(), SIGKILL)
    }

    /// The launch after `crash-blocks`: it gets going, the resolved text is back with no block
    /// left over, and it's saved without markers.
    static func recoverWithBlocks(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let text = document.editor.textView.string, both = "- ours \(marker)\n- theirs \(marker)\n"
        // The blocks Nib has are the text's own, none left from the file's longer text.
        log.check(text.contains(both) && ours(document, marker).isEmpty && document.blocks == ConflictText.blocks(in: text),
                  "the resolved text is back, and no block from the file is left over (\(document.blocks.count) blocks, the text's own)")
        let saved = await waitFor(20) { fileText(document).contains(both) }
        log.check(saved, "and it's saved, the block resolved in the file too")
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
        // Held first: a launch that finds iCloud still uploading the file holds it by a retry,
        // up to a minute on, and the merge needs a version this Mac uploaded while holding it
        // (the suite, 2026-10-02: unheld, it waited and typed, then had no such version).
        let since = Date()
        guard await waitFor(60, { document.held }) else {
            log.line("FAIL not held 60 s after the scenario began (state \(document.state.line))"); return
        }
        if Date().timeIntervalSince(since) > 1 { log.line("held \(Int(Date().timeIntervalSince(since))) s after the scenario began (iCloud still uploading at launch)") }
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
        NibDefaults.store.register(defaults: ["NibHoldUploads": true])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("- merge mine \(marker)\n", replacementRange: view.selectedRange())
        await endOfEvent(view)
        let saved = await waitFor(8) { fileText(document).contains("merge mine \(marker)") && !document.dirty }
        log.check(saved && document.unsent, "this Mac's line is saved, not uploaded")
        // The other Mac's version, the base plus a line at the end. Its note comes first, as it
        // mostly does from iCloud; or (-NibNoteTiming after) 3 s after the version, as at 20:55; or
        // (never) not at all.
        let timing = NibDefaults.store.string(forKey: "NibNoteTiming") ?? "before"
        let theirs = TextFile.encode(baseText + "- merge theirs \(marker)\n", as: document.format)
        let note = Announcement(sha256: Digest.sha256(theirs), parent: base, device: "Test Mac", size: theirs.count)
        if timing == "before" {
            try? note.write(for: document.url)
            try? await Task.sleep(for: .seconds(3))
        }
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        if timing == "before" {
            try? theirs.write(to: document.url)   // in place, as a fetch puts it there
        } else {
            fakeNewer = theirs                    // from iCloud, by a fetch: those wait for their note
            Task { await document.fetchLatest(reason: "test") }
        }
        func count(_ line: String) -> Int { view.string.components(separatedBy: line).count - 1 }
        if timing == "after" {
            try? await Task.sleep(for: .seconds(3))
            let waiting = events.read().dropFirst(before).contains { $0.event == "merge" && $0.detail?.contains("waiting up to 10 s for its note") == true }
            log.check(waiting && ours(document, marker).isEmpty && count("- merge theirs \(marker)") == 0,
                      "the version came before its note: the merge waits for it, nothing between markers yet")
            try? note.write(for: document.url)
        }
        if timing == "quit" {
            // Closed (as a quit closes it) while it waits for the note: the merge is made then, as the
            // 10 s would have made it, and saved. Closing in the wait left the other Mac's version in
            // the file, this Mac's line only in History, and the journal gone as clean (the suite,
            // 2026-10-07: `external`'s block in every block scenario after it).
            let waiting = await waitFor(5) { events.read().dropFirst(before).contains { $0.event == "merge" && $0.detail?.contains("waiting up to 10 s for its note") == true } }
            await document.close()
            let disk = fileText(document)
            log.check(waiting && disk.contains("merge mine \(marker)") && disk.contains("merge theirs \(marker)") && ConflictText.hasMarkers(disk),
                      "closed while it waited for the note: the file has both versions, between markers, not only the other Mac's (\(disk.contains("merge mine \(marker)") ? "this Mac's line there" : "this Mac's line missing"))")
            // The test file without the block, for the scenarios after it.
            var tidy = disk as NSString
            for block in ConflictText.blocks(in: disk).reversed() {
                tidy = tidy.replacingCharacters(in: block.range, with: ConflictText.resolution(of: block, .both, in: disk)) as NSString
            }
            try? (tidy as String).write(to: document.url, atomically: false, encoding: .utf8)
            NibDefaults.store.register(defaults: ["NibHoldUploads": false])
            return
        }
        if timing == "never" || timing == "late" {
            // The blocks and the Sync Log's line together: the line is written just after the blocks
            // go in, and read in between it wasn't there yet (the suite at 16:54, 2026-09-30).
            func conflictLine() -> SyncEvent? { events.read().dropFirst(before).last { $0.event == "conflict" } }
            let whole = await waitFor(15) { !ours(document, marker).isEmpty && conflictLine() != nil }
            let line = conflictLine()
            // Through the wait for its note, not a disk check taking it for another app's.
            log.check(whole && line?.detail?.contains("no version both had is known") == true && line?.detail?.hasPrefix("changed by another Mac") == true,
                      "no note in 10 s: both whole versions between markers, as before (\(line?.detail ?? "no conflict line"))")
            NibDefaults.store.register(defaults: ["NibHoldUploads": false])
            if timing == "never" {
                let conflicts = Notifier.shared.posted.filter { $0.kind == .conflict }
                log.check(conflicts.count == 1 && conflicts[0].title.hasPrefix("Conflict with ") && conflicts[0].title.hasSuffix(" in “\(document.url.lastPathComponent)”"),
                          "and a notification (SY15): “\(conflicts.first.map { $0.title + ": " + $0.body } ?? "none")”")
                // Both whole versions, not "1 place" (the QA review's F14), on the strip and in the notification.
                log.check(document.notice?.contains("BOTH WHOLE VERSIONS ARE IN THE TEXT") == true && document.notice?.contains("PLACE") == false
                          && conflicts.first?.body.hasPrefix("Both whole versions are in the text") == true,
                          "said as both whole versions, not 1 place: \(document.notice ?? "no notice")")
                let resolved = await keepBoth(document, marker)
                log.check(resolved, "and Keep Both resolves it")
                log.check(Notifier.shared.withdrawn.contains(.conflict), "resolved, the notification's taken back")
                return
            }
            // late: that merge goes up to iCloud first, then the note comes (20:55): it's still
            // proof of the version both had, and the blocks narrow to what both changed (nothing).
            await document.flush(reason: "test")
            let up = await waitFor(20) { isSynced(document) }
            try? await Task.sleep(for: .seconds(4))   // its own note written after each upload, then the other Mac's
            try? note.write(for: document.url)
            func upgrade() -> SyncEvent? { events.read().dropFirst(before).last { $0.event == "merge" && $0.detail?.hasPrefix("its note arrived") == true } }
            let narrowed = await waitFor(15) { upgrade() != nil && ours(document, marker).isEmpty }
            let upgrade = upgrade()
            log.check(up && narrowed && upgrade != nil && count("- merge mine \(marker)") == 1 && count("- merge theirs \(marker)") == 1,
                      "uploaded, then its note: merged from the version both had after all (\(upgrade?.detail ?? "no upgrade"))")
            let settled = await waitFor(30) { isSynced(document) && fileText(document) == view.string }
            let after = events.read().dropFirst(before).filter { ["upload", "fetch", "refresh", "reload"].contains($0.event) }.suffix(6)
            log.check(settled, "and that's saved and uploaded (\(document.state.line); \(after.map { $0.word }.joined(separator: ", ")))")
            return
        }
        var sheet = false
        let arrived = await waitFor(15) {
            if !ours(document, marker).isEmpty { sheet = true }
            return view.string.contains("merge theirs \(marker)")
        }
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
        // From a small window: it grows to hold the sheet, which fits in it (the QA review's F58:
        // the sheet's 760×560 hung past a window's 480×320).
        let frameBefore = view.window?.frame
        if let window = view.window, let frameBefore { window.setFrame(NSRect(x: frameBefore.minX, y: frameBefore.maxY - 360, width: 500, height: 360), display: true) }
        document.resolveConflicts()
        let opened = await waitFor(5) { document.merge != nil && view.window?.attachedSheet != nil }
        guard opened, let session = document.merge else { log.line("FAIL Resolve… didn't open the merge view"); return }
        log.check(true, "Resolve… with four blocks opened the merge view")
        try? await Task.sleep(for: .milliseconds(500))
        if let window = view.window, let sheet = window.attachedSheet {
            log.check(sheet.frame.width <= window.frame.width + 1 && sheet.frame.height <= window.frame.height + 1 && window.contentLayoutRect.width >= MergeView.minimum.width,
                      "from a 500×360 window: it grew to \(Int(window.frame.width))×\(Int(window.frame.height)), the sheet \(Int(sheet.frame.width))×\(Int(sheet.frame.height)) inside it")
        }
        // ⌥⌘R is Merge View…, always the merge view, as its ellipsis says ("Resolve…" went to the
        // next block with three or fewer: the QA review's F52).
        let conflictsMenu = NSApp.mainMenu?.items.first { $0.title == "Conflicts" }?.submenu
        log.check(conflictsMenu?.items.first { $0.title == "Merge View…" }?.keyEquivalent == "r" && conflictsMenu?.items.contains { $0.title == "Resolve…" } == false,
                  "Conflicts › Merge View… on ⌥⌘R, named for what it does")
        // Its titles and the blocks' key hints at 4.5:1 or more (the QA review's F59: about 4.1).
        let hint = RGBA(Scheme.legible(Scheme.comment, on: Scheme.conflictBlock)).contrast(RGBA(Scheme.conflictBlock))
        let title = RGBA(Scheme.legible(NSColor(HUDColor.dim), on: Scheme.background)).contrast(RGBA(Scheme.background))
        log.check(hint >= 4.5 && title >= 4.5, String(format: "the blocks' hints %.1f:1 and the panes' titles %.1f:1 on the page", hint, title))
        log.check(session.first.text.contains("mine 4 \(marker)") && !session.first.text.contains("theirs 1 \(marker)")
                  && session.second.text.contains("theirs 1 \(marker)") && !session.second.text.contains("mine 4 \(marker)"),
                  "each pane holds one version's whole text (\(session.first.label) · \(session.second.label))")
        log.check(session.marks.first.contains(.changed) && session.marks.second.contains(.changed), "and marks what differs (~)")
        // Each pane's title from all four blocks: their times' span, not the first block's time
        // for all of them (the QA review's F34).
        log.check(session.first.label == "\(document.device.uppercased()) · THIS MAC · 10:41-10:44" && session.second.label == "TEST MAC · 10:31-10:34",
                  "the panes' titles span every block: \(session.first.label) and \(session.second.label)")
        // The window's own commands, chosen with the sheet up, don't reach the text behind it (the QA
        // review's F31: Find opened the window's find bar under the sheet, Go to Line its strip field).
        func choose(_ path: [String]) -> String {
            var menu = NSApp.mainMenu
            for title in path.dropLast() { menu = menu?.items.first { $0.title == title }?.submenu }
            guard let menu, let index = menu.items.firstIndex(where: { $0.title == path.last }) else { return "missing" }
            menu.update()
            guard menu.items[index].isEnabled else { return "off" }
            menu.performActionForItem(at: index)
            return "chosen"
        }
        let tried = [choose(["Edit", "Find", "Find…"]), choose(["Text", "Go to Line…"]), choose(["View", "Show Sync Details"])]
        try? await Task.sleep(for: .milliseconds(400))
        log.check(!tried.contains("missing") && !document.editor.find.shown && !document.goingToLine && !document.syncDetailsShown,
                  "with the merge view up, Find, Go to Line and Show Sync Details (\(tried.joined(separator: ", "))) leave the window behind it alone")
        // From this run's first block (a block another scenario left in the test file would come
        // first, and be the one resolved).
        let own = session.blocks.first { (session.result as NSString).substring(with: $0.range).contains(marker) }
        if let own { session.editor.textView.setSelectedRange(NSRange(location: own.first.location, length: 0)) }
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
        if let frameBefore { view.window?.setFrame(frameBefore, display: true) }   // the window as it was
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
        NibDefaults.store.removeObject(forKey: "siblings:" + document.url.path)
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
        // Not the version as opened: the identical duplicate above was that one, already dealt with.
        // (Merges were "saved" in History until F55 named them; this took the opened one then.)
        let earlier = document.history.entries().last { $0.source != "opened" && $0.sha256 != now }
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

    /// Files and tabs (ED2): a test file opens in its own window, as a tab beside another file's
    /// and never the scratch window's; opening it again brings the same window forward, one
    /// buffer per file; typing saves it; closing its tab hands it back to iCloud; and a file
    /// outside the test folders is refused before it's read (the M1 safety rule, §8).
    /// ⌘C as a person presses it, in a file that isn't the scratch file (the user's report,
    /// 2026-10-10: typed text, ⌘C, and another app pasted what the clipboard had before). The
    /// other scenarios call `copy(_:)` on the view; this one posts the key, so the menu's key
    /// equivalent and the responder chain are in it too. The clipboard is put back.
    static func copyKeyScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("copykey-\(marker).md")
        try? Data("Copy key, generated by the copykey scenario.\n".utf8).write(to: url)
        let saved = savePasteboard()
        defer {
            restorePasteboard(saved)
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            ScenarioFocus.giveBackNow()
        }
        AppDelegate.openFile(url)
        let opened = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard opened, let document = Documents.existing(for: url) else { log.check(false, "the file opens"); return }
        let view = document.editor.textView
        let pasteboard = NSPasteboard.general
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
            guard let window = view.window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(110))
        }
        func where_() -> String {
            let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil).map { String(describing: Swift.type(of: $0)) } ?? "nothing"
            let first = NSApp.keyWindow?.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"
            return "key window \(NSApp.keyWindow === view.window ? "the file's" : String(describing: NSApp.keyWindow?.title)), first responder \(first), copy goes to \(target)"
        }
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        _ = await waitFor(5) { NSApp.isActive && view.window?.isKeyWindow == true && view.window?.firstResponder === view }

        // Typed at the end, selected, ⌘C.
        let start = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: start, length: 0))
        for (letter, code) in [("c", UInt16(8)), ("o", 31), ("p", 35), ("y", 16)] { await key(letter, code) }
        _ = await waitFor(2) { (view.string as NSString).length == start + 4 }
        let typed = (view.string as NSString).substring(from: start)
        view.setSelectedRange(NSRange(location: start, length: (typed as NSString).length))
        pasteboard.clearContents()
        pasteboard.setString("before-\(marker)", forType: .string)
        log.line("typed “\(typed)”; \(where_())")
        await key("c", 8, .command)
        let byKey = await waitFor(2) { pasteboard.string(forType: .string) == "copy" }
        log.check(byKey, "⌘C in a file's window: the typed text on the clipboard (\(pasteboard.string(forType: .string).debugDescription); \(where_()))")

        // Edit › Copy, from the menu.
        pasteboard.clearContents()
        pasteboard.setString("before-\(marker)", forType: .string)
        if let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu,
           let index = edit.items.firstIndex(where: { $0.title == "Copy" }) {
            edit.performActionForItem(at: index)
        }
        let byMenu = await waitFor(2) { pasteboard.string(forType: .string) == "copy" }
        log.check(byMenu, "Edit › Copy in a file's window: the same (\(pasteboard.string(forType: .string).debugDescription))")

        // The same in the scratch file's tab, for comparison.
        let scratch = Documents.scratch.editor.textView
        scratch.window?.makeKeyAndOrderFront(nil)
        scratch.window?.makeFirstResponder(scratch)
        _ = await waitFor(3) { scratch.window?.isKeyWindow == true }
        let length = min(4, (scratch.string as NSString).length)
        scratch.setSelectedRange(NSRange(location: 0, length: length))
        let expected = (scratch.string as NSString).substring(to: length)
        pasteboard.clearContents()
        pasteboard.setString("before-\(marker)", forType: .string)
        if let window = scratch.window {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "c",
                                                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        let inScratch = await waitFor(2) { pasteboard.string(forType: .string) == expected }
        log.check(length > 0 && inScratch, "⌘C in the scratch file: its selection on the clipboard (\(pasteboard.string(forType: .string).debugDescription))")

        // Every menu item with C for its key, as the menu bar has them now.
        func items(_ menu: NSMenu, _ path: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                let here = item.keyEquivalent.lowercased() == "c"
                    ? ["\(path)\(item.title) [\(item.keyEquivalentModifierMask.rawValue)/\(item.keyEquivalent)\(item.isEnabled ? "" : ", off")]"] : []
                return here + (item.submenu.map { items($0, path + item.title + " › ") } ?? [])
            }
        }
        log.line("menu items on C: " + (NSApp.mainMenu.map { items($0, "") } ?? []).joined(separator: "; "))

        // A new untitled tab (⌘N), typed in, selected, ⌘C.
        let before = Set(Documents.all.map(\.url))
        AppDelegate.newUntitled()
        _ = await waitFor(10) { Documents.all.contains { !before.contains($0.url) && $0.ready && $0.editor.textView.window?.isVisible == true } }
        if let buffer = Documents.all.first(where: { !before.contains($0.url) }) {
            let text = buffer.editor.textView
            text.window?.makeKeyAndOrderFront(nil)
            text.window?.makeFirstResponder(text)
            _ = await waitFor(3) { text.window?.isKeyWindow == true && text.window?.firstResponder === text }
            if let window = text.window {
                for (letter, code) in [("n", UInt16(45)), ("e", 14), ("w", 13)] {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: letter,
                                                        charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(110))
                }
                _ = await waitFor(2) { text.string == "new" }
                text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
                pasteboard.clearContents()
                pasteboard.setString("before-\(marker)", forType: .string)
                let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil).map { String(describing: Swift.type(of: $0)) } ?? "nothing"
                let key = NSApp.keyWindow
                log.line("untitled: key window is its \(key === window), key \(String(describing: key.map { Swift.type(of: $0) })) “\(key?.title ?? "")”, its first responder \(String(describing: key?.firstResponder.map { Swift.type(of: $0) })); the tab's first responder \(String(describing: window.firstResponder.map { Swift.type(of: $0) })), is the text \(window.firstResponder === text); main \(NSApp.mainWindow === window); text responds \(text.responds(to: #selector(NSText.copy(_:)))), next \(String(describing: text.nextResponder.map { Swift.type(of: $0) }))")
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "c",
                                                    charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                let copied = await waitFor(2) { pasteboard.string(forType: .string) == "new" }
                log.check(copied, "⌘C in a new untitled tab: “\(text.string)” on the clipboard (\(pasteboard.string(forType: .string).debugDescription); copy goes to \(target))")
            }
            Untitled.letGo(buffer.url)
            text.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: buffer.url) == nil }
        } else {
            log.check(false, "⌘N opens a new untitled tab")
        }

        // A file in a git repository (outside iCloud, as `gitmarks`): its marks redrawn as it's typed in.
        if GitRepo.installed {
            let repo = ScratchLocation.localTestFolder.appendingPathComponent("copykey-git-\(marker)", isDirectory: true)
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            let tracked = repo.appendingPathComponent("notes.md")
            try? Data("one\ntwo\n".utf8).write(to: tracked)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "git init -q -b main && git config user.email test@example.com && git config user.name Test && git add notes.md && git commit -q -m first"]
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            AppDelegate.openFile(tracked)
            _ = await waitFor(10) { Documents.existing(for: tracked)?.ready == true && Documents.existing(for: tracked)?.editor.textView.window?.isVisible == true }
            if let document = Documents.existing(for: tracked), let window = document.editor.textView.window {
                let text = document.editor.textView
                ScenarioFocus.take()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(text)
                _ = await waitFor(5) { NSApp.isActive && window.isKeyWindow && window.firstResponder === text && document.git.status == .tracked(branch: "main") }
                text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
                for (letter, code) in [("g", UInt16(5)), ("i", 34), ("t", 17)] {
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: letter,
                                                        charactersIgnoringModifiers: letter, isARepeat: false, keyCode: code) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(110))
                }
                let marked = await waitFor(3) { !document.git.changes.isEmpty }
                let end = (text.string as NSString).length
                text.setSelectedRange(NSRange(location: end - 3, length: 3))
                pasteboard.clearContents()
                pasteboard.setString("before-\(marker)", forType: .string)
                let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil).map { String(describing: Swift.type(of: $0)) } ?? "nothing"
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "c",
                                                    charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                let copied = await waitFor(2) { pasteboard.string(forType: .string) == "git" }
                log.check(copied, "⌘C in a file in a git repository, its marks shown (\(marked)): the typed text on the clipboard (\(pasteboard.string(forType: .string).debugDescription); copy goes to \(target); key window its \(NSApp.keyWindow === window))")
                text.undoManager?.undo()
                await document.flush(reason: "harness")
                window.performClose(nil)
                _ = await waitFor(15) { Documents.existing(for: tracked) == nil }
            } else {
                log.check(false, "the file in a git repository opens")
            }
            NibDefaults.store.removeObject(forKey: "selection:" + tracked.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == tracked.path }) { ClosedItems.shared.forget(item) }
            try? FileManager.default.removeItem(at: repo)
        }

        view.undoManager?.undo()
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    static func files(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let folder = ScratchLocation.url.deletingLastPathComponent()
        let a = folder.appendingPathComponent("files-a-\(marker).md"), b = folder.appendingPathComponent("files-b-\(marker).md")
        try? Data("File A, generated by the files scenario.\n".utf8).write(to: a)
        try? Data("File B, generated by the files scenario.\n".utf8).write(to: b)
        defer {
            // This scenario's own generated files, out again.
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        func window(_ url: URL) -> NSWindow? { Documents.existing(for: url)?.editor.textView.window }
        AppDelegate.openFile(a)
        let openA = await waitFor(10) { Documents.existing(for: a)?.ready == true && window(a)?.isVisible == true }
        log.check(openA && window(a) !== Documents.scratch.editor.textView.window, "a file opens in its own window, not the scratch window")
        AppDelegate.openFile(b)
        let openB = await waitFor(10) { Documents.existing(for: b)?.ready == true && window(b) != nil }
        _ = await waitFor(3) { window(a)?.tabGroup?.windows.contains { $0 === window(b) } == true }
        // Just created, and iCloud's helper often doesn't answer at first: held all the same, on a later try.
        let bothHeld = await waitFor(60) { Documents.existing(for: a)?.held == true && Documents.existing(for: b)?.held == true }
        let tries = [a, b].map { url -> String in
            guard Documents.existing(for: url)?.held == true else { return "not held in 60 s" }
            return SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read()
                .last { $0.path == url.path && $0.event == "pause" && ($0.detail == nil || $0.detail!.hasPrefix("held")) }?.detail ?? "held at once"
        }
        log.check(bothHeld, "both new files are held (\(tries.joined(separator: ", ")))")
        // One window, as Sublime's (A5, the user's call, 2026-10-02): the scratch file a tab with them.
        let scratchWindow = Documents.scratch.editor.textView.window
        log.check(openB && window(a)?.tabGroup?.windows.contains { $0 === window(b) } == true
                  && window(a)?.tabGroup?.windows.contains { $0 === scratchWindow } == true,
                  "a second file is a tab beside it, and the scratch file a tab in the same window (\(window(a)?.tabGroup?.windows.count ?? 0) tabs; id \(window(b)?.tabbingIdentifier ?? "none"))")

        // File › New (⌘N) and New Tab (⌘T): an empty file, a tab in the window in front, in
        // Markdown. File › Close (⌘W): the tab in front (the window, when it's the only one).
        let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
        func key(_ title: String) -> String? {
            file?.items.first { $0.title == title }.map { ($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "") + "⌘" + $0.keyEquivalent.uppercased() }
        }
        log.check(key("New") == "⌘N" && key("New Tab") == "⌘T" && key("Close") == "⌘W",
                  "File: New \(key("New") ?? "none"), New Tab \(key("New Tab") ?? "none"), Close \(key("Close") ?? "none")")
        let before = Set(Documents.all.map(\.url))
        ScenarioFocus.take()
        scratchWindow?.makeKeyAndOrderFront(nil)
        if let index = file?.items.firstIndex(where: { $0.title == "New Tab" }) { file?.performActionForItem(at: index) }
        let made = await waitFor(10) { Documents.all.contains { !before.contains($0.url) && $0.untitled && $0.ready && $0.editor.textView.window != nil } }
        let fresh = Documents.all.first { !before.contains($0.url) && $0.untitled }
        log.check(made && fresh.flatMap { $0.editor.textView.window?.tabGroup?.windows.contains { $0 === scratchWindow } } == true
                  && fresh?.pickedSyntax == .language(.markdown) && fresh?.editor.textView.string.isEmpty == true,
                  "New Tab from the scratch file: an empty file, a tab beside it, in Markdown (\(fresh?.url.lastPathComponent ?? "none"), \(fresh?.pickedSyntax?.name ?? "automatic"))")
        if let fresh, let tab = fresh.editor.textView.window {
            let url = fresh.url
            // Close goes to the window in front, as ⌘W from the keys: this tab, once it's there.
            ScenarioFocus.take()
            tab.makeKeyAndOrderFront(nil)
            var inFront = await waitFor(5) { NSApp.keyWindow === tab }
            // ("Close Tab" in a window of tabs, as Apple says it: the QA review's F78. SwiftUI makes
            // the menu's items as it opens, as the palette has it do: the File menu afresh, brought
            // up to date. In front as it's read: another app coming forward takes the key window.)
            func fileMenu() -> NSMenu? {
                let menu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
                if let menu { PaletteSession.refresh(menu) }
                return menu
            }
            _ = await waitFor(3) { fileMenu()?.items.contains { $0.title == "Close Tab" } == true || NSApp.keyWindow !== tab }
            inFront = inFront && NSApp.keyWindow === tab
            let file = fileMenu()
            let closeTitle = file?.items.first { ["Close", "Close Tab"].contains($0.title) }?.title ?? "none"
            if let index = file?.items.firstIndex(where: { $0.title == closeTitle }) { file?.performActionForItem(at: index) }
            log.check((closeTitle == "Close Tab" || !inFront) && file?.items.contains { $0.title == "Close Window" && $0.keyEquivalent.lowercased() == "w" } == true,
                      "in a window of tabs, File says Close Tab (⌘W) and Close Window (⇧⌘W): “\(closeTitle)”"
                      + (closeTitle == "Close Tab" ? "" : " (Rune active \(NSApp.isActive), the tab key \(NSApp.keyWindow === tab), its tabs \(tab.tabbedWindows?.count ?? 0), tabbed \(KeyWindowTabs.shared.tabbed))"))
            let closed = await waitFor(10) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
            // (Its document not made again as its window went: `FileWindow.document`.)
            var detail = closed ? "closed" : "still open"
            if !inFront { detail += ", not in front" }
            if let listed = Documents.existing(for: url), listed !== fresh { detail += ", another document made for it" }
            log.check(closed && scratchWindow?.isVisible == true, "File › Close closes the tab in front, the others staying, its file let go (\(detail))")
            if !closed {   // not left for the next launch
                Untitled.letGo(url)
                tab.performClose(nil)
                _ = await waitFor(10) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
            }
        }
        ScenarioFocus.giveBackNow()
        if let tabs = window(b), let frame = tabs.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            try? await Task.sleep(for: .milliseconds(500))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-files.png"))
        }
        let first = Documents.existing(for: a)
        AppDelegate.openFile(a)
        let front = await waitFor(5) { window(a)?.tabGroup?.selectedWindow === window(a) }
        log.check(front && Documents.existing(for: a) === first, "opening it again brings the same window forward, the same buffer")
        if let document = Documents.existing(for: a) {
            let view = document.editor.textView
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertText("- typed in a file \(marker)\n", replacementRange: view.selectedRange())
            let saved = await waitFor(10) { ((try? String(contentsOf: a, encoding: .utf8)) ?? "").contains("typed in a file \(marker)") }
            log.check(saved, "typing in it saves it (\(document.state.line))")
            window(a)?.performClose(nil)
            let closed = await waitFor(15) { Documents.existing(for: a) == nil && !PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json")).all().contains(a.path) }
            log.check(closed, "closing its tab closes its buffer and hands the file back to iCloud")
            // Its History window, left open, can't write into it any more (the QA review's F2:
            // Restore there replaced the closed buffer and saved it into the file).
            _ = await waitFor(10) { document.closed }
            let onDisk = try? Data(contentsOf: a)
            let oldest = document.history.entries().first
            if let oldest { document.restore(oldest) }
            await document.flush(reason: "test")
            try? await Task.sleep(for: .milliseconds(500))
            log.check(document.closed && oldest != nil && (try? Data(contentsOf: a)) == onDisk && !document.dirty,
                      "once closed, Restore (of its oldest version) and saving leave its file alone")
        }
        window(b)?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: b) == nil }

        // A file outside iCloud Drive (the QA review's F6): saved is all there is, "✓ SAVED", not
        // "= SAVED LOCALLY" for good with the menu bar marching.
        let local = ScratchLocation.localTestFolder.appendingPathComponent("local-\(marker).md")
        try? FileManager.default.createDirectory(at: ScratchLocation.localTestFolder, withIntermediateDirectories: true)
        try? Data("# Local \(marker)\n".utf8).write(to: local)
        // Last changed two days ago: opened, it says that time, with its day (the QA review's F13
        // and F65: the time it opened, as if saved then, and no day).
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400).addingTimeInterval(-37)
        try? FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: local.path)
        AppDelegate.openFile(local)
        _ = await waitFor(10) { Documents.existing(for: local)?.ready == true }
        if let file = Documents.existing(for: local) {
            let saidAt = file.savedAt.map { abs($0.timeIntervalSince(twoDaysAgo)) < 1 } == true
            log.check(saidAt && file.statusLine == "✓ SAVED · \(SyncState.moment(twoDaysAgo))" && file.uploadedAt == nil,
                      "opened, its version's own time and day, not the time it opened: “\(file.statusLine)”")
            await type("- typed in a file on this Mac only \(marker)\n", into: file)
            await file.flush(reason: "test")
            let saved = await waitFor(10) { if case .savedHere = file.state { true } else { false } }
            log.check(saved && file.statusLine.hasPrefix("✓ SAVED · ") && !MenuBarState.pending(file) && !file.inICloud,
                      "a file outside iCloud Drive: “\(file.statusLine)”, not waiting on iCloud, the menu bar still")
            file.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: local) == nil }
        } else {
            log.check(false, "a file outside iCloud Drive opened")
        }
        try? FileManager.default.removeItem(at: local)
        ClosedItems.removeKept(for: local.path)
        if let item = ClosedItems.shared.items.first(where: { $0.path == local.path }) { ClosedItems.shared.forget(item) }
        RecentFiles.shared.remove(local)
        // Outside the test folders: refused, and nothing read.
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nib-refusal-\(marker).md")
        try? Data("Generated text outside the test folders.\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        AppDelegate.openFile(outside)
        let refused = await waitFor(10) { Documents.existing(for: outside)?.locked != nil }
        log.check(refused && Documents.existing(for: outside)?.editor.textView.string.isEmpty == true,
                  "a file outside the test folders: refused, nothing read (\(Documents.existing(for: outside)?.locked ?? "not refused"))")
        Documents.existing(for: outside)?.editor.textView.window?.performClose(nil)
        _ = await waitFor(5) { Documents.existing(for: outside) == nil }
    }

    /// The syntax menu (HL1): a file whose name says nothing is plain text; picking a syntax
    /// highlights it without an edit, the file keeps the pick, and Automatic undoes it.
    static func syntaxScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).txt")
        let text = "// Generated by the syntax scenario.\nfunction add(note) {\n  return note;\n}\n"
        try? Data(text.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "syntax:" + url.path)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
        }
        func open() async -> Document? {
            AppDelegate.openFile(url)
            _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url)
        }
        func close() async {
            Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil }
        }
        // The parameter `note`: italic when highlighted as JavaScript (An Old Hope, HL5).
        let note = (text as NSString).range(of: "note").location
        func italic(_ document: Document) -> Bool {
            let font = document.editor.textView.textStorage?.attribute(.font, at: note, effectiveRange: nil) as? NSFont
            return font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
        }
        guard let document = await open() else { log.check(false, "the file opened"); return }
        log.check(document.syntaxName == "PLAIN TEXT" && document.pickedSyntax == nil && !italic(document),
                  "a .txt file is plain text (\(document.syntaxName))")
        document.pickSyntax(.language(.javascript))
        let highlighted = await waitFor(5) { italic(document) }
        log.check(document.syntaxName == "JAVASCRIPT" && highlighted, "picking JavaScript highlights it (\(document.syntaxName), parameter italic \(highlighted))")
        try? await Task.sleep(for: .seconds(1.5))
        log.check(!document.dirty && ((try? String(contentsOf: url, encoding: .utf8)) ?? "") == text,
                  "and isn't an edit: nothing to save, the file unchanged (\(document.state.line))")
        let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        let items = view?.items.first { $0.title == "Syntax" }?.submenu?.items.map(\.title).filter { !$0.isEmpty } ?? []
        let missing = SyntaxPick.all.map(\.name).filter { !items.contains($0) }
        log.check(items.contains("Automatic (Plain Text)") && missing.isEmpty && SyntaxPick.all.count == SyntaxLanguage.allCases.count,
                  "View › Syntax has Automatic and the \(SyntaxPick.all.count - 1) languages, by name (\(items.joined(separator: ", ")))")
        if let window = document.editor.textView.window, let frame = window.contentView?.superview,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-syntax.png"))
        }
        await close()
        guard let again = await open() else { log.check(false, "the file opened again"); return }
        let kept = await waitFor(5) { italic(again) }
        log.check(again.syntaxName == "JAVASCRIPT" && again.pickedSyntax == .language(.javascript) && kept, "the file keeps the pick when opened again (\(again.syntaxName))")
        again.pickSyntax(nil)
        let plain = await waitFor(5) { !italic(again) }
        log.check(again.syntaxName == "PLAIN TEXT" && plain && NibDefaults.store.string(forKey: "syntax:" + url.path) == nil,
                  "Automatic goes back to what the file's name says (\(again.syntaxName))")
        again.pickSyntax(.language(.shell))
        log.check(again.editor.syntax?.root == "source.shell.bash", "Shell on a file that doesn't say zsh is Bash (\(again.editor.syntax?.root ?? "none"))")
        await close()

        // XML (HL8): a plist, which Sublime finds by its first line, colored as Sublime colors it;
        // Toggle Comment with XML's marks.
        let plistURL = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<!-- generated by the syntax scenario -->
        \t<key>Label</key>
        \t<string>com.example.\(marker) &amp; more</string>
        </dict>
        </plist>

        """
        try? Data(plist.utf8).write(to: plistURL)
        defer {
            try? FileManager.default.removeItem(at: plistURL)
            NibDefaults.store.removeObject(forKey: "syntax:" + plistURL.path)
            NibDefaults.store.removeObject(forKey: "selection:" + plistURL.path)
        }
        AppDelegate.openFile(plistURL)
        _ = await waitFor(10) { Documents.existing(for: plistURL)?.ready == true && Documents.existing(for: plistURL)?.editor.textView.window?.isVisible == true }
        guard let xml = Documents.existing(for: plistURL) else { log.check(false, "the plist opened"); return }
        let xview = xml.editor.textView, xs = plist as NSString
        func drawn(_ word: String, _ shift: Int = 0) -> String { drawnColor(xview, at: xs.range(of: word).location + shift) }
        let colored = await waitFor(5) { drawn("<key>", 1) == "#EC475D" }
        let colors = [drawn("<key>", 1), drawn("plist version", 6), drawn("-//Apple"), drawn("generated"), drawn("amp;"), drawn("DOCTYPE plist", 8)]
        log.check(xml.syntaxName == "XML" && colored && colors == ["#EC475D", "#E7CE57", "#50B4D8", "#848484", "#EF7C2B", "#78BC65"],
                  "a .plist whose first line is <?xml is XML (\(xml.syntaxName)): tag, attribute, string, comment, entity and DOCTYPE in Sublime's colors (\(colors.joined(separator: " ")))")
        if let window = xview.window, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-syntax-xml.png"))
        }
        xview.setSelectedRange(NSRange(location: xs.range(of: "<key>").location, length: 0))
        xview.toggleComment(nil)
        let commented = (xview.string as NSString).range(of: "\t<!-- <key>Label</key> -->\n").location != NSNotFound
        xml.editor.undo.undo()
        log.check(commented && xview.string == plist, "Toggle Comment uses <!-- --> (undone after)")
        xml.editor.textView.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: plistURL) == nil }

        // HL8's list: a .py file is Python, drawn in Sublime's colors (one language for the app's
        // part; NibKit's tests and the fidelity harness hold the others).
        let pyURL = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).py")
        let py = "\"\"\"Generated by the syntax scenario.\"\"\"\nimport json\n\n\ndef total(items: list[int]) -> int:\n    return sum(items)  # every item\n"
        try? Data(py.utf8).write(to: pyURL)
        defer {
            try? FileManager.default.removeItem(at: pyURL)
            NibDefaults.store.removeObject(forKey: "selection:" + pyURL.path)
        }
        AppDelegate.openFile(pyURL)
        _ = await waitFor(10) { Documents.existing(for: pyURL)?.ready == true && Documents.existing(for: pyURL)?.editor.textView.window?.isVisible == true }
        guard let python = Documents.existing(for: pyURL) else { log.check(false, "the .py file opened"); return }
        let pview = python.editor.textView, ps = py as NSString
        func pdrawn(_ word: String) -> String { drawnColor(pview, at: ps.range(of: word).location) }
        let pcolored = await waitFor(5) { pdrawn("def") == "#EC475D" }
        let pcolors = [pdrawn("def"), pdrawn("total"), pdrawn("items:"), pdrawn("list"), pdrawn("Generated"), pdrawn("every")]
        log.check(python.syntaxName == "PYTHON" && pcolored && pcolors == ["#EC475D", "#E7CE57", "#EF7C2B", "#50B4D8", "#848484", "#848484"],
                  "a .py file is Python (\(python.syntaxName)): keyword, function, parameter, type, docstring and comment in Sublime's colors (\(pcolors.joined(separator: " ")))")
        pview.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: pyURL) == nil }

        // Swift (HL8), which Sublime doesn't ship: Nib's own colors, the scopes Sublime gives the
        // same things in its other languages.
        let swiftURL = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).swift")
        let swiftText = "// Generated by the syntax scenario.\nfinal class Store {\n    func load(_ url: URL) { print(\"loading \\(url)\") }\n}\n"
        try? Data(swiftText.utf8).write(to: swiftURL)
        defer {
            try? FileManager.default.removeItem(at: swiftURL)
            NibDefaults.store.removeObject(forKey: "selection:" + swiftURL.path)
        }
        AppDelegate.openFile(swiftURL)
        _ = await waitFor(10) { Documents.existing(for: swiftURL)?.ready == true && Documents.existing(for: swiftURL)?.editor.textView.window?.isVisible == true }
        guard let swiftDocument = Documents.existing(for: swiftURL) else { log.check(false, "the .swift file opened"); return }
        let sview = swiftDocument.editor.textView, ss = swiftText as NSString
        func sdrawn(_ word: String) -> String { drawnColor(sview, at: ss.range(of: word).location) }
        let scolored = await waitFor(5) { sdrawn("final") == "#EC475D" }
        let scolors = [sdrawn("final"), sdrawn("Store"), sdrawn("load"), sdrawn("url:"), sdrawn("URL"), sdrawn("print"), sdrawn("loading"), sdrawn("Generated")]
        log.check(swiftDocument.syntaxName == "SWIFT" && scolored && scolors == ["#EC475D", "#E7CE57", "#E7CE57", "#EF7C2B", "#50B4D8", "#50B4D8", "#50B4D8", "#848484"],
                  "a .swift file is Swift (\(swiftDocument.syntaxName)): keyword, class, function, parameter, type, builtin, string and comment in Rune's own colors (\(scolors.joined(separator: " ")))")
        sview.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: swiftURL) == nil }

        // CSV and logs (HL8), Nib's own colors with no tree: a .csv file's columns in turn (a
        // quoted field over two lines in one), a .log file's timestamps, levels, strings and
        // numbers. A snapshot of each.
        func snapshot(_ view: NSTextView, _ name: String) {
            guard let frame = view.window?.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent(name))
        }
        let csvURL = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).csv")
        let csvText = "id,title,published,duration,downloads,rating,url\n1,\"Plain, Text\nForever\",2026-09-14,42:17,18250,4.8,https://example.com/1\n2,Hot Exit,2026-10-02,29:40,,4.7,https://example.com/2\n"
        let logURL = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("syntax-\(marker).log")
        let logText = "2026-10-02 17:24:01.123 INFO  [sync] opened \"scratch.md\" in 112ms\n2026-10-02 17:24:09.002 WARN  [upload] retrying in 15s\n2026-10-02 17:24:24.871 ERROR [upload] failed: storage full\n"
        try? Data(csvText.utf8).write(to: csvURL)
        try? Data(logText.utf8).write(to: logURL)
        defer {
            for url in [csvURL, logURL] {
                try? FileManager.default.removeItem(at: url)
                NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            }
        }
        for (url, text, name, words, expected) in [
            (csvURL, csvText, "CSV", ["id", "Plain", "Forever", "2026", "42:17", "18250", "4.8", "https", ","],
             ["none", "#EC475D", "#EC475D", "#E7CE57", "#78BC65", "#50B4D8", "#EF7C2B", "none", "none"]),   // plain: no color drawn
            (logURL, logText, "LOG", ["2026", "INFO", "sync", "scratch", "112ms", "WARN", "ERROR", "failed"],
             ["#848484", "#78BC65", "none", "#50B4D8", "#EF7C2B", "#E7CE57", "#EC475D", "#EC475D"]),
        ] {
            AppDelegate.openFile(url)
            _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            guard let document = Documents.existing(for: url) else { log.check(false, "the \(name) file opened"); return }
            let view = document.editor.textView, ns = text as NSString
            func drawn(_ word: String) -> String { drawnColor(view, at: ns.range(of: word).location) }
            let colored = await waitFor(5) { drawn(words[1]) == expected[1] }
            let colors = words.map(drawn)
            log.check(document.syntaxName == name && colored && colors == expected,
                      "a .\(url.pathExtension) file is \(name) (\(document.syntaxName)), in Rune's own colors: \(zip(words, colors).map { "\($0) \($1)" }.joined(separator: ", "))")
            snapshot(view, "snapshot-syntax-\(url.pathExtension).png")
            view.window?.performClose(nil)
            _ = await waitFor(15) { Documents.existing(for: url) == nil }
        }
    }

    /// Uploads while typing goes on (§4.3 step 7; 2026-10-06, the user's call): 30 s of typing at
    /// a person's pace, a keystroke every quarter second, saved every 5 s or so; uploaded once at
    /// its start and every 20 s after, not after every save; then 3 s after the last keystroke,
    /// the last of it, synced.
    static func uploadsScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 30)
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        let view = document.editor.textView
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("\n- uploads \(marker) ", replacementRange: view.selectedRange())
        let started = Date()
        var n = 0
        while Date().timeIntervalSince(started) < 30 {
            n += 1
            view.insertText(n % 40 == 0 ? "\n" : "x", replacementRange: view.selectedRange())
            try? await Task.sleep(for: .milliseconds(250))
        }
        let lastKey = Date()
        let synced = await waitFor(20) {
            isSynced(document) && fileText(document) == document.editor.textView.string
                && document.debugSnapshot.uploadedSHA == document.debugSnapshot.baseSHA
        }
        let mine = events.read().dropFirst(before).filter { $0.path == document.url.path }
        let saves = mine.filter { $0.event == "save" }
        let uploads = mine.filter { $0.event == "upload" && $0.detail == nil }
        let during = uploads.filter { $0.time <= lastKey }, after = uploads.filter { $0.time > lastKey }
        let lastUpload = uploads.last.map { $0.time.timeIntervalSince(lastKey) }
        log.check(saves.count >= 5 && during.count <= 3 && after.count == 1 && synced,
                  "30 s of typing: \(saves.count) saves, \(during.count) uploads while it went on, \(after.count) after it stopped"
                  + (lastUpload.map { String(format: " (%.1f s after the last keystroke)", $0) } ?? "") + ", synced \(synced)")
    }

    /// ⌘F in a scratch-sized file (2026-10-04: Find crashed the Nib in daily use twice, in
    /// AppKit's `__NSTextViewScrollContainerViewToTextRange`, laying out the view after a jump):
    /// matches far apart in 223 KB, gone to by typing in the bar, by Return there and by ⌘G from
    /// the text, a keystroke at once after each; Nib still running, every keystroke in the text.
    static func findJumpScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        var text = "# Find jump \(marker)\n\n", n = 0
        while text.utf8.count < 225_000 {
            n += 1
            if n % 700 == 0 { text += "- needle \(marker) at line \(n)\n" }
            else if n % 9 == 0 { text += "- item \(n) with `code` and **bold** text\n" }
            else { text += "Line \(n): ordinary prose of a scratch file's length, wrapping in a window of ordinary width.\n" }
        }
        guard let url = Untitled.create(text: text, name: "findjump-\(marker).md") else { log.check(false, "a 223 KB buffer"); return }
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else {
            log.check(false, "it opened")
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())   // or it comes back at the next launch
            return
        }
        let view = document.editor.textView, find = document.editor.find
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        _ = await waitFor(5) { view.window?.isKeyWindow == true }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var typed = 0, unseen: [Int] = []
        /// After a jump: is the selection's place in view?
        func inView() {
            let at = view.selectedRange().location
            if let rect = view.placeRect(at: at), view.visibleRect.contains(NSPoint(x: rect.minX, y: rect.midY)) { return }
            unseen.append(at)
        }
        /// A keystroke at the caret right after a jump, as a person might, then the colors' pass.
        func keystroke() async {
            view.insertText("x", replacementRange: NSRange(location: view.selectedRange().location, length: 0))
            typed += 1
            try? await Task.sleep(for: .milliseconds(400))
        }
        find.open(replace: false)
        find.query = "needle \(marker)"
        let first = await waitFor(5) { find.current != nil }
        log.line("typing in the bar: on a match \(first), at \(view.selectedRange().location) of \((view.string as NSString).length)")
        inView()
        await keystroke()
        for round in 0..<8 {
            // Return in the bar, then ⌘G from the text (where AppKit's find indicator shows), round the end.
            if round % 2 == 1 { view.window?.makeFirstResponder(view) } else { view.window?.makeFirstResponder(nil) }
            find.next(backwards: round >= 6)
            log.line("round \(round + 1): at \(view.selectedRange().location)")
            inView()
            await keystroke()
        }
        find.close()
        try? await Task.sleep(for: .seconds(1))
        log.check((view.string as NSString).length == (text as NSString).length + typed && unseen.isEmpty,
                  "Find's jumps in 223 KB and a keystroke after each: still running, each match brought into view, all \(typed) keystrokes in the text"
                  + (unseen.isEmpty ? "" : " (not in view: \(unseen))"))

        // The same by the keyboard, as a person does it: real key events, ⌘F, the query typed a
        // letter at a time into the bar's field, Return there, Escape, ⌘G from the text, typing.
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
            guard let window = view.window else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await Task.sleep(for: .milliseconds(110))
        }
        ScenarioFocus.take()
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        _ = await waitFor(5) { NSApp.isActive && view.window?.isKeyWindow == true }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        let before = (view.string as NSString).length
        await key("f", 3, .command)
        let opened = await waitFor(3) { find.shown }
        for (letter, code) in [("n", UInt16(45)), ("e", 14), ("e", 14), ("d", 2), ("l", 37), ("e", 14)] { await key(letter, code) }
        let onMatch = await waitFor(3) { find.current != nil }
        log.line("by the keyboard: the bar \(opened), the query “\(find.query)”, on a match \(onMatch) at \(view.selectedRange().location)")
        unseen = []
        for _ in 0..<4 { await key("\r", 36); try? await Task.sleep(for: .milliseconds(250)); inView() }
        log.line("Return ×4: at \(view.selectedRange().location), not in view after \(unseen)")
        await key("\u{1b}", 53)
        let closed = await waitFor(2) { !find.shown && view.window?.firstResponder === view }
        try? await Task.sleep(for: .milliseconds(300))   // the bar gone, the text its height again
        inView()
        log.line("Escape: the bar closed and the text first responder \(closed); not in view after \(unseen)")
        // Posted keys reach the menu only while Nib is the active app: the focus taken again.
        ScenarioFocus.take()
        _ = await waitFor(5) { NSApp.isActive && view.window?.isKeyWindow == true && view.window?.firstResponder === view }
        var places: [Int] = []
        for _ in 0..<3 {
            await key("g", 5, .command)
            _ = await waitFor(1) { view.selectedRange().location != places.last ?? -1 }
            try? await Task.sleep(for: .milliseconds(150))
            places.append(view.selectedRange().location)
            inView()
        }
        log.line("⌘G ×3 from the text: at \(places), not in view after \(unseen)")
        view.setSelectedRange(NSRange(location: NSMaxRange(view.selectedRange()), length: 0))
        for _ in 0..<3 { await key("x", 7) }
        try? await Task.sleep(for: .seconds(1))
        // The buffer let go, and gone before the scenario ends: a quit before its close is done
        // left it, to come back as a tab at every launch after (the suite, 2026-10-06: `fileops`
        // found 16 tabs, not 5).
        Untitled.letGo(url)
        view.window?.performClose(nil)
        let gone = await waitFor(15) { !FileManager.default.fileExists(atPath: url.path) }
        if !gone { log.line("the buffer was still there after 15 s") }
        log.check(opened && onMatch && Set(places).count == 3 && unseen.isEmpty && (view.string as NSString).length == before + 3,
                  "by the keyboard (⌘F, the query, Return, Escape, ⌘G ×3 moving each time, typing): still running, each match in view, the 3 keystrokes in the text (\((view.string as NSString).length - before))"
                  + (unseen.isEmpty ? "" : " (not in view: \(unseen))"))
    }

    /// App Nap (2026-10-02): a scenario's Nib out of sight keeps its timers on time. Napped,
    /// its 50 ms waits took 250 ms from about 30 s out of sight on (with the screen locked, the
    /// suite's `merge` waited 35 s for a hold, then typed its line, 30 ms a keystroke). Hidden
    /// for 40 s, a 50 ms wait is timed throughout, then a line is typed, still out of sight.
    static func napScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        NSApp.hide(nil)
        let started = Date()
        // Napped, nearly every wait runs long from about 30 s on; one slow wait as the app hides,
        // or under a moment's load, isn't that (the suite at 15:37 on 2026-10-06: 345 ms at 0 s).
        var longest = 0.0, firstLong: Double?, long = 0, waits = 0
        while Date().timeIntervalSince(started) < 40 {
            let before = Date()
            try? await Task.sleep(for: .milliseconds(50))
            let took = Date().timeIntervalSince(before)
            guard Date().timeIntervalSince(started) > 2 else { continue }
            waits += 1
            longest = max(longest, took)
            if took > 0.2 { long += 1; if firstLong == nil { firstLong = Date().timeIntervalSince(started) } }
        }
        let line = "\n- typed out of sight \(marker)\n"
        let typing = Date()
        await type(line, into: document)
        let typed = Date().timeIntervalSince(typing)
        NSApp.unhideWithoutActivation()
        log.check(long <= 2, "hidden for 40 s, not napped: \(long) of \(waits) 50 ms waits over 200 ms, the longest \(Int(longest * 1000)) ms"
                  + (firstLong.map { "; the first at \(Int($0)) s" } ?? ""))
        log.check(typed < Double(line.count) * 0.03 + 2, "and \(line.count) keystrokes, 30 ms apart, took \(String(format: "%.1f", typed)) s")
    }

    /// Theme import (HL2-HL4): a scheme file, then Import from Sublime Text from a generated
    /// Sublime folder (a .tmTheme with a Packages/User override, a font), then the original An
    /// Old Hope, which keeps the Nib edition. The editor redraws each time without an edit.
    /// Everything it changes (the scheme, the font, the report, the Themes folder) is put back.
    static func themes(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let defaults = NibDefaults.store
        let keys = ["scheme", "editorFontFace", "editorFontSize", "schemeReport", "editorTabSize", "editorSpaces", "editorWordWrap"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let schemes = Schemes.shared
        let (before, beforeFace, beforeSize) = (schemes.currentID, schemes.fontFace, schemes.fontSize)
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: Schemes.folder.path)) ?? [])
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nib-themes-\(marker)")
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("themes-\(marker).md")
        let text = "# Generated by the themes scenario\n\nSome *text*.\n"
        try? Data(text.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: scratch)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
        }
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView
        func hex(_ color: NSColor?) -> String {
            guard let c = color?.usingColorSpace(.sRGB) else { return "none" }
            return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        func drawn(at location: Int) -> String { drawnColor(view, at: location) }
        let heading = 2   // "Generated", in the heading
        _ = await waitFor(5) { drawn(at: heading) == "#E7CE57" }
        log.check(schemes.currentID == before && drawn(at: heading) == "#E7CE57", "the heading in An Old Hope · Rune's yellow (\(drawn(at: heading)))")

        // A scheme file: a light .sublime-color-scheme with variables and color().
        try? FileManager.default.createDirectory(at: scratch.appendingPathComponent("Packages/User"), withIntermediateDirectories: true)
        let paper = scratch.appendingPathComponent("Paper.sublime-color-scheme")
        try? Data("""
        { // generated by the themes scenario
          "name": "Scenario Paper \(marker)",
          "variables": { "ink": "#202020", "blue": "hsl(210, 60%, 40%)" },
          "globals": { "background": "#FAFAF7", "foreground": "var(ink)", "caret": "var(blue)", "line_highlight": "color(var(ink) alpha(0.06))", "selection": "#CCE0F5", "guide": "#DDDDDD" },
          "rules": [ { "name": "Heading", "scope": "markup.heading", "foreground": "var(blue)", "font_style": "bold" } ],
        }
        """.utf8).write(to: paper)
        schemes.importFile(paper)
        let blue = "#2966A3"
        let recolored = await waitFor(5) { drawn(at: heading) == blue }
        log.check(schemes.current.name == "Scenario Paper \(marker)" && hex(view.backgroundColor) == "#FAFAF7" && recolored,
                  "Import File: the scheme is used, background \(hex(view.backgroundColor)), heading \(drawn(at: heading))")
        let report = schemes.report ?? ""
        log.check(report.contains("IMPORTED SCENARIO PAPER") && report.contains("1 RULE · 6 GLOBALS USED") && !report.contains("NOT DRAWN")
                  && report.contains("LIGHT BACKGROUND · RUNE'S WINDOWS STAY DARK"), "and reported: \(report)")
        log.check(NSApp.effectiveAppearance.name == .darkAqua && view.window?.effectiveAppearance.name == .darkAqua, "Rune's windows stay dark")
        try? await Task.sleep(for: .seconds(1))
        log.check(!document.dirty && !document.editor.undo.canUndo && ((try? String(contentsOf: url, encoding: .utf8)) ?? "") == text,
                  "a new scheme isn't an edit: nothing to save or undo, the file unchanged")
        if let window = view.window, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-themes.png"))
        }

        // Import from Sublime Text: a generated Sublime whose scheme is a .tmTheme in a
        // package, with an override in Packages/User, Menlo 15 and two-space tabs.
        defaults.set(scratch.path, forKey: "NibSublimeFolder")
        defaults.set(scratch.appendingPathComponent("no-app").path, forKey: "NibSublimePackages")
        defer {
            NibDefaults.store.removeObject(forKey: "NibSublimeFolder")
            NibDefaults.store.removeObject(forKey: "NibSublimePackages")
        }
        let plist: [String: Any] = ["name": "Scenario Dark \(marker)", "settings": [
            ["settings": ["background": "#101820", "foreground": "#E0E0E0", "caret": "#FFCC00", "lineHighlight": "#182028"]],
            ["name": "Heading", "scope": "markup.heading", "settings": ["foreground": "#FF8800", "fontStyle": "bold"]],
        ]]
        try? FileManager.default.createDirectory(at: scratch.appendingPathComponent("Packages/Scenario"), withIntermediateDirectories: true)
        try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: scratch.appendingPathComponent("Packages/Scenario/Scenario Dark.tmTheme"))
        try? Data("{ \"rules\": [ { \"scope\": \"markup.heading\", \"foreground\": \"#00CC88\" } ], } // the override".utf8)
            .write(to: scratch.appendingPathComponent("Packages/User/Scenario Dark.sublime-color-scheme"))
        try? Data("{ \"color_scheme\": \"Packages/Scenario/Scenario Dark.tmTheme\", \"font_face\": \"Menlo\", \"font_size\": 15, \"tab_size\": 2, \"translate_tabs_to_spaces\": true, }".utf8)
            .write(to: scratch.appendingPathComponent("Packages/User/Preferences.sublime-settings"))
        schemes.importFromSublime()
        let fromSublime = await waitFor(5) { drawn(at: heading) == "#00CC88" }
        log.check(schemes.current.name == "Scenario Dark \(marker)" && hex(view.backgroundColor) == "#101820" && fromSublime,
                  "Import from Sublime Text: its scheme with the override (heading \(drawn(at: heading)))")
        log.check(view.font?.familyName == "Menlo" && view.font?.pointSize == 15 && (view.textStorage?.attribute(.font, at: 20, effectiveRange: nil) as? NSFont)?.pointSize == 15,
                  "and its font: \(view.font?.fontName ?? "none") \(view.font?.pointSize ?? 0)")
        let sublimeReport = schemes.report ?? ""
        log.check(sublimeReport.contains("WITH SCENARIO DARK.SUBLIME-COLOR-SCHEME") && sublimeReport.contains("FONT MENLO 15")
                  && sublimeReport.contains("TAB SIZE 2 · SPACES"), "and reported: \(sublimeReport)")
        // Settings › Themes, with the report, rendered.
        let tab = defaults.object(forKey: "settingsTab")
        defaults.set("themes", forKey: "settingsTab")
        let known = Set(NSApp.windows.map(ObjectIdentifier.init))
        if let menu = NSApp.mainMenu?.items.first?.submenu, let index = menu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) {
            menu.performActionForItem(at: index)
        }
        _ = await waitFor(5) { NSApp.windows.contains { !known.contains(ObjectIdentifier($0)) && $0.isVisible } }
        if let settings = NSApp.windows.first(where: { !known.contains(ObjectIdentifier($0)) && $0.isVisible }) {
            try? await Task.sleep(for: .milliseconds(600))
            if let frame = settings.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-settings.png"))
            }
            settings.close()
        }
        if let tab { defaults.set(tab, forKey: "settingsTab") } else { defaults.removeObject(forKey: "settingsTab") }

        // The original An Old Hope: Nib keeps its edition.
        let original: [String: Any] = ["name": "an-old-hope", "settings": [["settings": ["background": "#1C1D21", "foreground": "#F8F8F2"]],
                                       ["name": "Number", "scope": "constant.numeric", "settings": ["foreground": "#7851A9"]]]]
        try? PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: scratch.appendingPathComponent("Packages/User/an-old-hope.tmTheme"))
        try? Data("{ \"color_scheme\": \"Packages/User/an-old-hope.tmTheme\" }".utf8)
            .write(to: scratch.appendingPathComponent("Packages/User/Preferences.sublime-settings"))
        schemes.importFromSublime()
        let back = await waitFor(5) { drawn(at: heading) == "#E7CE57" }
        log.check(schemes.currentID == Schemes.builtIn && back && (schemes.report ?? "").contains("KEPT AN OLD HOPE · RUNE"),
                  "the original An Old Hope keeps the Rune edition (\(schemes.report ?? "no report"))")

        // Put back what the scenario changed.
        for id in Set((try? FileManager.default.contentsOfDirectory(atPath: Schemes.folder.path)) ?? []).subtracting(beforeFiles) { schemes.remove(id) }
        schemes.setFont(face: beforeFace, size: beforeSize)
        schemes.use(before)
        for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        view.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: url) == nil }
    }

    /// Untitled buffers (ED3), first launch: ⌘N, journaled and saved on this Mac only, out of
    /// the Sync Log; closing one keeps it in History and ⇧⌘T brings it back; an empty one just
    /// goes; Save… makes one a file (in the test folders only). Then typing that only the
    /// journal has, and a crash: `untitled-return` checks what comes back. Saving waits
    /// (-NibSaveIdle 600) so only the journal has that typing.
    static func untitledScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        func newBuffer() async -> Document? {
            let known = Set(Untitled.all().map(\.path))
            AppDelegate.newUntitled()
            var found: Document?
            _ = await waitFor(10) {
                found = Untitled.all().first { !known.contains($0.path) }.flatMap { Documents.existing(for: $0) }
                return found?.ready == true && found?.editor.textView.window?.isVisible == true
            }
            return found
        }
        func close(_ document: Document) async {
            let url = document.url
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: url) == nil && !FileManager.default.fileExists(atPath: url.path) }
        }
        func onDisk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        func openBuffer(_ text: String, _ name: String) async -> Document? {
            guard let url = Untitled.create(text: text, name: name) else { return nil }
            AppDelegate.openFile(url)
            _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            return Documents.existing(for: url)
        }
        func historyFolder(_ url: URL) -> URL { History(root: NibPaths.support.appendingPathComponent("History"), path: url.path).directory }
        guard let one = await newBuffer() else { log.check(false, "⌘N opened an untitled buffer"); return }
        let name = one.url.lastPathComponent
        log.check(one.untitled && name.hasPrefix("Untitled") && one.editor.textView.window?.title == name,
                  "⌘N: a new untitled buffer, “\(name)”, in a window of its own")
        await type("untitled one \(marker)\n", into: one)
        let journaled = await waitFor(3) { journal.read(path: one.url.path)?.text.contains("untitled one \(marker)") == true }
        log.check(journaled, "its typing is in the journal within a moment")
        await one.flush(reason: "test")
        log.check(onDisk(one.url).contains("untitled one \(marker)") && one.state.line.hasPrefix("= ON THIS MAC ONLY"),
                  "and saved in Rune's own folder, on this Mac only (\(one.state.line))")
        let syncLog = (try? String(contentsOf: NibPaths.support.appendingPathComponent("sync.jsonl"), encoding: .utf8)) ?? ""
        log.check(!syncLog.contains(Untitled.folder.path), "nothing about it in the Sync Log: it never syncs")
        // Save…'s name for it: the extension of the syntax picked for it (the QA review's F71: ".txt" for JavaScript).
        let asIs = Untitled.suggestedName(one)
        one.pickSyntax(.language(.javascript))
        let asJS = Untitled.suggestedName(one)
        one.pickSyntax(nil)
        let base = (name as NSString).deletingPathExtension
        log.check(asIs == ((name as NSString).pathExtension.isEmpty ? base + ".md" : name) && asJS == base + ".js",
                  "Save… suggests “\(asIs)”, and “\(asJS)” once JavaScript is picked")

        guard let two = await newBuffer() else { log.check(false, "a second untitled buffer"); return }
        let twoURL = two.url, twoName = twoURL.lastPathComponent
        _ = await waitFor(3) { one.editor.textView.window?.tabGroup?.windows.contains { $0 === two.editor.textView.window } == true }
        log.check(twoName != name && one.editor.textView.window?.tabGroup?.windows.contains { $0 === two.editor.textView.window } == true,
                  "a second one, “\(twoName)”, is a tab beside it")
        await type("untitled two \(marker)\n", into: two)
        if let window = two.editor.textView.window, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            try? await Task.sleep(for: .milliseconds(500))
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-untitled.png"))
        }
        await close(two)
        let history = History(root: NibPaths.support.appendingPathComponent("History"), path: twoURL.path)
        let kept = history.entries().last.flatMap { history.data($0.sha256) }.map { TextFile.decode($0).text } ?? ""
        log.check(!FileManager.default.fileExists(atPath: twoURL.path) && kept.contains("untitled two \(marker)")
                  && ClosedItems.shared.items.first?.path == twoURL.path,
                  "closing it asks nothing: its text is in History and on Reopen Closed File (\(history.entries().last?.source ?? "none"))")
        ClosedItems.shared.reopenLast()
        let back = await waitFor(10) { Documents.existing(for: twoURL)?.ready == true && Documents.existing(for: twoURL)?.editor.textView.string.contains("untitled two \(marker)") == true }
        log.check(back && ClosedItems.shared.items.first?.path != twoURL.path, "⇧⌘T brings it back, “\(twoName)” as it was")

        guard let three = await newBuffer() else { log.check(false, "a third untitled buffer"); return }
        let threeURL = three.url
        await close(three)
        // Its History too: each ⌘N closed untouched had left a folder with its empty version (§8, 2026-10-03).
        log.check(!FileManager.default.fileExists(atPath: threeURL.path) && !ClosedItems.shared.items.contains { $0.path == threeURL.path }
                  && !FileManager.default.fileExists(atPath: historyFolder(threeURL).path) && NibDefaults.store.object(forKey: "syntax:" + threeURL.path) == nil,
                  "an empty one just goes: nothing kept, History and all")
        // Typed in, then emptied: kept, as a closed buffer is, so that text stays in History (guarantee 2).
        if let emptied = await openBuffer("emptied \(marker)\n", "emptied-\(marker).md") {
            let url = emptied.url
            emptied.editor.textView.selectAll(nil)
            emptied.editor.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            await emptied.flush(reason: "test")
            await close(emptied)
            let history = History(root: NibPaths.support.appendingPathComponent("History"), path: url.path)
            let earlier = history.entries().contains { history.data($0.sha256) == Data("emptied \(marker)\n".utf8) }
            log.check(ClosedItems.shared.items.first?.path == url.path && earlier && history.entries().last?.size == 0,
                      "one typed in, then emptied: on Reopen Closed File, the text it had in its History (\(history.entries().map(\.source)))")
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        // The scenarios' buffers, let go: nothing left, History and all (`large` had left 92 MB a run, §8).
        if let goner = await openBuffer("let go \(marker)\n", "letgo-\(marker).md") {
            let url = goner.url
            Untitled.letGo(url)
            await close(goner)
            log.check(!FileManager.default.fileExists(atPath: historyFolder(url).path) && !ClosedItems.shared.items.contains { $0.path == url.path },
                      "a buffer let go (the scenarios'): nothing kept, History and all")
        }

        guard let four = await newBuffer() else { log.check(false, "a fourth untitled buffer"); return }
        let fourURL = four.url
        await type("saved as a file \(marker)\n", into: four)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nib-untitled-\(marker).txt")
        let refused = await Untitled.save(four, to: outside)
        log.check(!refused && !FileManager.default.fileExists(atPath: outside.path) && four.notice?.contains("RUNE OPENS ONLY TEST FILES") == true,
                  "Save… outside the test folders: refused, nothing written (\(four.notice ?? "no notice"))")
        let target = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("untitled-saved-\(marker).txt")
        let caret = four.editor.textView.selectedRange().location
        let saved = await Untitled.save(four, to: target)
        let opened = await waitFor(10) { Documents.existing(for: target)?.ready == true && Documents.existing(for: fourURL) == nil }
        log.check(saved && opened && onDisk(target) == "saved as a file \(marker)\n" && !FileManager.default.fileExists(atPath: fourURL.path)
                  && !ClosedItems.shared.items.contains { $0.path == fourURL.path },
                  "Save…: the text in the file, the file open in its place, the untitled buffer gone")
        // Its History and caret went with it (guarantee 2): left at its path, nothing opened or thinned them again (§8, 2026-10-03).
        let targetHistory = Documents.existing(for: target)?.history.entries() ?? []
        log.check(targetHistory.contains { $0.size == 0 } && targetHistory.contains { $0.sha256 == Digest.sha256(Data("saved as a file \(marker)\n".utf8)) }
                  && !FileManager.default.fileExists(atPath: historyFolder(fourURL).path)
                  && Documents.existing(for: target)?.editor.textView.selectedRange().location == caret,
                  "and its History (\(targetHistory.map(\.source))) and caret went with it, nothing left at the untitled buffer's path")
        Documents.existing(for: target)?.editor.textView.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: target) == nil }
        if let item = ClosedItems.shared.items.first(where: { $0.path == target.path }) { ClosedItems.shared.forget(item) }
        // Gone now, not in a defer: this scenario ends in SIGKILL, and one was left each run. Its
        // History too: nothing opens that path again.
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: historyFolder(target))
        for prefix in ["selection:", "syntax:"] { NibDefaults.store.removeObject(forKey: prefix + target.path) }

        // Reopen Closed File keeps 20: an untitled buffer pushed off goes, History and all (it had
        // stayed for good, §8, 2026-10-03).
        if let pushed = await openBuffer("pushed off \(marker)\n", "pushed-\(marker).md") {
            let url = pushed.url
            await close(pushed)
            let listed = ClosedItems.shared.items.first?.path == url.path && FileManager.default.fileExists(atPath: historyFolder(url).path)
            let fillers = (1...20).map { ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("closed-\(marker)-\($0).txt") }   // paths only
            for file in fillers { ClosedItems.shared.add(.init(path: file.path, name: file.lastPathComponent, untitled: false, sha256: nil, time: Date())) }
            log.check(listed && !ClosedItems.shared.items.contains { $0.path == url.path } && !FileManager.default.fileExists(atPath: historyFolder(url).path),
                      "Reopen Closed File keeps 20: an untitled buffer pushed off goes, History and all")
            for item in ClosedItems.shared.items where fillers.contains(where: { $0.path == item.path }) { ClosedItems.shared.forget(item) }
        }

        // Typing only the journal has, then a crash.
        await type("after the save \(marker)\n", into: one)
        let inJournal = await waitFor(3) { journal.read(path: one.url.path)?.text.contains("after the save \(marker)") == true }
        log.check(inJournal && !onDisk(one.url).contains("after the save"), "more typing: in the journal, not yet in the file")
        log.line("SIGKILL")
        kill(getpid(), SIGKILL)
    }

    /// The launch after `untitled`: both untitled buffers are back (hot exit), the first with
    /// the typing only the journal had. Then they're closed and forgotten, History and all.
    static func untitledReturn(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        var mine: [Document] = []
        _ = await waitFor(15) {
            mine = Untitled.all().compactMap { Documents.existing(for: $0) }.filter { $0.ready && $0.editor.textView.string.contains(marker) }
            return mine.count >= 2 && mine.contains { $0.editor.textView.string.contains("after the save \(marker)") }
        }
        let one = mine.first { $0.editor.textView.string.contains("untitled one \(marker)") }
        let two = mine.first { $0.editor.textView.string.contains("untitled two \(marker)") }
        log.check(one?.editor.textView.string.contains("after the save \(marker)") == true && one?.editor.textView.window?.isVisible == true,
                  "after a crash, the untitled buffer is back with the typing only the journal had (\(one?.notice ?? "no notice"))")
        log.check(two?.editor.textView.window?.isVisible == true, "and the one ⇧⌘T brought back is too")
        let saved = await waitFor(10) { one.map { ((try? String(contentsOf: $0.url, encoding: .utf8)) ?? "").contains("after the save \(marker)") } ?? false }
        log.check(saved, "and the recovered typing is saved")
        for document in mine {
            let url = document.url
            document.editor.textView.window?.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: url) == nil }
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        log.check(mine.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) }, "closed and forgotten, History and all")
        // One more, left open for an ordinary quit: `untitled-quit` checks it comes back.
        AppDelegate.newUntitled()
        var last: Document?
        _ = await waitFor(10) {
            last = Untitled.all().compactMap { Documents.existing(for: $0) }.first { $0.ready && $0.editor.textView.string.isEmpty }
            return last != nil
        }
        if let last { await type("left open at quit \(marker)\n", into: last) }
        log.check(last != nil, "one more left open, then an ordinary quit")
    }

    /// The files open at a quit, open again at the next launch (`OpenTabs`; the user's call,
    /// 2026-10-07: only the scratch window came back). With -NibReopenFiles YES (a test run's Nib
    /// doesn't otherwise): two files outside iCloud and an untitled buffer, in that order after the
    /// scratch file, the first file's tab in front; then the ordinary quit records them.
    static func reopenFiles(_ marker: String) -> [URL] {
        ["a", "b"].map { ScratchLocation.localTestFolder.appendingPathComponent("reopen-\($0)-\(marker).md") }
    }

    static func reopenScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let files = reopenFiles(marker)
        try? FileManager.default.createDirectory(at: ScratchLocation.localTestFolder, withIntermediateDirectories: true)
        for file in files { try? Data("# \(file.lastPathComponent)\n".utf8).write(to: file) }
        for file in files {
            AppDelegate.openFile(file)
            _ = await waitFor(10) { Documents.existing(for: file)?.ready == true && Documents.existing(for: file)?.editor.textView.window?.isVisible == true }
        }
        guard let buffer = Untitled.create(text: "# Reopen untitled \(marker)\n", name: "reopen-\(marker).md") else { log.check(false, "an untitled buffer"); return }
        AppDelegate.openFile(buffer)
        _ = await waitFor(10) { Documents.existing(for: buffer)?.editor.textView.window?.isVisible == true }
        // The first file's tab in front.
        if let window = Documents.existing(for: files[0])?.editor.textView.window {
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        let open = (files + [buffer]).allSatisfy { Documents.existing(for: $0)?.editor.textView.window?.isVisible == true }
        // Their order in the tabs, as it is (a new tab goes in beside the one selected), for the next launch to compare.
        let tabs = Documents.existing(for: files[0])?.editor.textView.window?.tabGroup?.windows ?? []
        let names = tabs.compactMap { tab in Documents.all.first { $0.editor.textView.window === tab } }.filter { $0 !== Documents.scratch }.map(\.url.lastPathComponent)
        NibDefaults.store.set(names, forKey: "reopenScenarioOrder")
        // Each new tab at the end, in the order they were opened (the user's call, 2026-10-07: each
        // went in after the scratch file's, so "scratch, buffer, B, A").
        let opened = (files + [buffer]).map(\.lastPathComponent)
        log.check(open && names == opened, "two files and an untitled buffer open, each tab at the end, in the order opened (\(names.joined(separator: ", "))), the first file in front; quitting records them")
    }

    /// The launch after `reopen`: the three are back, in their order after the scratch file, the
    /// first file in front; then they're closed, and what they left removed.
    static func reopenReturn(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let files = reopenFiles(marker)
        let buffer = Untitled.all().first { $0.lastPathComponent == "reopen-\(marker).md" }
        let all = files + (buffer.map { [$0] } ?? [])
        func window(_ url: URL) -> NSWindow? { Documents.existing(for: url)?.editor.textView.window }
        let back = await waitFor(20) { all.count == 3 && all.allSatisfy { window($0)?.isVisible == true } }
        let tabs = window(files[0])?.tabGroup?.windows ?? []
        let names = tabs.compactMap { tab in Documents.all.first { $0.editor.textView.window === tab } }.filter { $0 !== Documents.scratch }.map(\.url.lastPathComponent)
        let before = NibDefaults.store.stringArray(forKey: "reopenScenarioOrder") ?? []
        NibDefaults.store.removeObject(forKey: "reopenScenarioOrder")
        let front = window(files[0])?.tabGroup?.selectedWindow === window(files[0])
        log.check(back && names == before && front,
                  "the files open at the quit are back, in their tabs' order (\(names.joined(separator: ", ")); at the quit \(before.joined(separator: ", "))), the first file in front (\(front)), the untitled buffer too")
        // With the scratch file, not after its hold and iCloud's questions (the user, 2026-10-07:
        // they came 1-2 s after its text).
        func ms(_ date: Date?) -> Int? { date.flatMap { d in AppDelegate.launchMoments.text.map { Int(d.timeIntervalSince($0) * 1000) } } }
        let tabsAt = ms(OpenTabs.restoredAt), openedAt = ms(AppDelegate.scratchOpenedAt)
        log.check(tabsAt.map { $0 <= 1000 } == true,
                  "and with the scratch file: all in \(tabsAt.map { "\($0) ms" } ?? "never") after its text, its open done (held, iCloud asked) at \(openedAt.map { "\($0) ms" } ?? "not yet")")
        // Not at the launch after: the list is used once (and this run's quit records none of them).
        log.check(NibDefaults.store.stringArray(forKey: OpenTabs.listKey) == nil, "and the list is used once")
        for url in all {
            if Untitled.contains(url) { Untitled.letGo(url) }
            window(url)?.performClose(nil)
        }
        _ = await waitFor(15) { all.allSatisfy { Documents.existing(for: $0) == nil } }
        for file in files {
            try? FileManager.default.removeItem(at: file)
            ClosedItems.removeKept(for: file.path)
            for item in ClosedItems.shared.items where item.path == file.path { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(file)
            for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + file.path) }
        }
    }

    /// The launch after `untitled-return`'s ordinary quit: the untitled buffer left open is back.
    static func untitledQuit(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        var back: Document?
        _ = await waitFor(15) {
            back = Untitled.all().compactMap { Documents.existing(for: $0) }.first { $0.ready && $0.editor.textView.string.contains("left open at quit \(marker)") }
            return back?.editor.textView.window?.isVisible == true
        }
        log.check(back != nil, "after quitting, the untitled buffer left open is back (\(back?.url.lastPathComponent ?? "not found"))")
        if let back {
            let url = back.url
            back.editor.textView.window?.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: url) == nil }
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
    }

    /// A hold iCloud's helper doesn't answer (§4.3; the Sync Log window's first day): the file
    /// opens and saves unheld, is held on a later try, and what was saved meanwhile is uploaded;
    /// closing hands it back. Run with -NibFailPauses 2 -NibFailPausesFor hold-.
    static func holdRetryScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("hold-\(marker).md")
        try? Data("Generated by the holdretry scenario.\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let opened = Date()
        AppDelegate.openFile(url)
        _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        log.check(!document.held && document.editor.textView.isEditable, "iCloud's helper doesn't answer: the file opens unheld, and can be edited")
        await type("- typed while unheld \(marker)\n", into: document)
        let saved = await waitFor(10) { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("typed while unheld \(marker)") }
        log.check(saved, "typing saves while it's unheld")
        // Up to a minute: a try that finds iCloud still uploading the file (the typing above, just
        // saved) leaves it unpaused for a later one (§4.3; the suite at 16:38 on 2026-10-02 held it
        // on try 4, 38 s after opening, where this allowed try 3 and 20 s).
        let held = await waitFor(60) { document.held }
        log.check(held, "held on a later try, \(Int(Date().timeIntervalSince(opened))) s after opening")
        let lines = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().filter { $0.path == url.path && $0.event == "pause" }
        let expected = 1 + NibDefaults.store.integer(forKey: "NibFailPauses") + NibDefaults.store.integer(forKey: "NibUnsupportedPauses")
        let waitedOut = lines.dropFirst(expected - 1).dropLast()   // tries after the made-up failures, before the hold
        log.check(lines.first?.detail?.hasPrefix("not held yet") == true && lines.last?.detail == "held on try \(expected + waitedOut.count)"
                      && waitedOut.allSatisfy { $0.detail?.contains("still uploading") == true },
                  "the Sync Log says so: \(lines.map { $0.detail ?? "held" }.joined(separator: " / "))")
        let uploaded = await waitFor(20) { !document.dirty && document.debugSnapshot.uploadedSHA != nil && document.debugSnapshot.uploadedSHA == document.debugSnapshot.baseSHA }
        log.check(uploaded, "what was saved meanwhile is uploaded (\(document.state.line))")
        document.editor.textView.window?.performClose(nil)
        let closed = await waitFor(15) { Documents.existing(for: url) == nil && !PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json")).all().contains(url.path) }
        log.check(closed, "closing hands it back to iCloud")
        if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
    }

    /// An upload refused while iCloud says there's nothing newer (the two-Mac test at 20:02):
    /// Nib refreshes anyway, and the typing survives it, into the file and uploaded.
    static func refusal(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 20)
        // The other side's name in a marker: "iCloud" as Apple writes it (the QA review's F9: it
        // came out "ICloud" in the markers, the banner, the menu and the notification).
        log.check(Document.label("iCloud") == "iCloud" && Document.label("another Mac") == "Another Mac" && Document.label("the file") == "The file",
                  "a conflict's other side named in its marker: \(["iCloud", "another Mac", "the file"].map(Document.label).joined(separator: ", "))")
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        // Blocks an earlier scenario left aren't this one's (the suite, 2026-10-02: a hand-back
        // refused at a quit came back as a journal's conflict at the next launch).
        func blocks() -> Int { fileText(document).components(separatedBy: "<<<<<<< ").count - 1 }
        let blocksBefore = blocks()
        refuseUploads = 1
        staleFetches = 1
        await type("\n- typed before a refused upload \(marker)\n", into: document)
        let refreshed = await waitFor(30) { events.read().dropFirst(before).contains { $0.event == "refresh" } }
        let lines = events.read().dropFirst(before).filter { ["upload", "fetch", "refresh", "merge", "update"].contains($0.event) }
        log.check(refreshed && lines.contains { $0.detail?.hasPrefix("iCloud says there's nothing newer") == true },
                  "refused, and iCloud says nothing's newer: Rune refreshes anyway (\(lines.map { $0.word }.joined(separator: ", ")))")
        let kept = await waitFor(30) {
            fileText(document).contains("typed before a refused upload \(marker)") && isSynced(document)
                && document.editor.textView.string.contains("typed before a refused upload \(marker)")
        }
        log.check(kept, "the typing survives the refresh: in the buffer and the file, uploaded (\(document.state.line))")
        let after = events.read().dropFirst(before)
        log.check(!after.contains { $0.event == "conflict" } && blocks() == blocksBefore,
                  "and the refresh brought back only what this Mac had uploaded: nothing new between markers (\(after.map { $0.word }.joined(separator: ", "))"
                  + (blocksBefore > 0 ? "; \(blocksBefore) left by earlier scenarios" : "") + ")")
        log.check(refuseUploads == 0 && staleFetches == 0, "and the pretend refusal and stale answer were both used")
    }

    /// Handing the file back at quit fails twice, as when iCloud's helper doesn't answer: the
    /// file is left paused and listed, not handed back taking the server's version.
    /// `handback-return` checks the next launch.
    static func handBack(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        await waitSynced(document, 20)
        log.check(document.held, "the file is held (\(document.state.line))")
        failResumes = 2   // both tries at quit
    }

    /// The launch after `handback`, run with -NibFailResumes 1: the file was left paused;
    /// handing it back fails once more, so it's held as it is (the pause is this Mac's own),
    /// and what's there is uploaded, refusing to overwrite a newer version.
    static func handBackReturn(_ document: Document, _ log: HarnessLog) async {
        await waitReady(document)
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().filter { $0.path == document.url.path }
        let quit = events.last { $0.event == "resume" && $0.detail?.hasPrefix("handing it back failed twice") == true }
        log.check(quit != nil, "the last quit: \(quit?.detail ?? "no line about it")")
        let opened = events.last { $0.event == "open" }?.time ?? .distantPast
        let now = events.filter { $0.time >= opened }
        let held = now.first { $0.event == "pause" }
        log.check(document.held && held?.detail?.hasSuffix("holding it as it is") == true,
                  "left paused, and handing it back fails again: held as it is (\(held?.detail ?? "no pause line"))")
        let synced = await waitFor(20) { isSynced(document) }
        let uploads = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().filter { $0.path == document.url.path && $0.time >= opened && $0.event == "upload" }
        log.check(synced && !uploads.isEmpty, "and uploaded, fail-on-conflict (\(document.state.line))")
        log.check(PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json")).all().contains(document.url.path), "and listed as paused, for its own quit to hand back")
    }

    /// The highlighting color drawn at a character (a rendering attribute, §6.3), as hex.
    static func drawnColor(_ view: NSTextView, at location: Int, _ key: NSAttributedString.Key = .foregroundColor) -> String {
        guard let layout = view.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location) else { return "none" }
        var found: NSColor?
        layout.enumerateRenderingAttributes(from: start, reverse: false) { _, attributes, range in
            if range.contains(start) { found = attributes[key] as? NSColor }
            return false
        }
        guard let c = found?.usingColorSpace(.sRGB) else { return "none" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /// A scratch-sized file (§6.5: 2.4 MB of Markdown): colors soon after it opens, at the end
    /// once scrolled there, and on a heading typed there; typing isn't held up meanwhile.
    static func bigFile(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("big-\(marker).md")
        var text = "# Big file \(marker)\n", n = 0
        while text.utf8.count < 2_400_000 {
            n += 1
            switch n % 200 {
            case 0: text += "```bash\nrsync -av --progress ./dist/ me@seedbox:~/www/ && echo \"done \(n)\"\n```\n"
            case 50: text += "## Notes for \(n)\n"
            default:
                if n % 25 == 0 { text += String(repeating: "A long email paragraph that wraps, pasted from the thread about item \(n), ", count: 5) + "\n" }
                else if n % 3 == 0 { text += "- item \(n) with `code` and **bold** text\n" }
                else { text += "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
            }
        }
        text += "## The last heading \(marker)\n"
        try? Data(text.utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            NibDefaults.store.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        let opened = Date()
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView
        let yellow = "#E7CE57"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scroll(.zero)
        let top = await waitFor(10) { drawnColor(view, at: 2) == yellow }
        log.check(top, "\(text.utf8.count / 1000) KB, \(n) lines: the heading at the top colored \(Int(Date().timeIntervalSince(opened) * 1000)) ms after asking to open it")
        let length = (view.string as NSString).length
        let last = (view.string as NSString).range(of: "## The last heading").location
        let scrolled = Date()
        view.reveal(length)
        let bottom = await waitFor(5) { drawnColor(view, at: last + 3) == yellow }
        log.check(bottom, "scrolled to the end: the last heading colored \(Int(Date().timeIntervalSince(scrolled) * 1000)) ms later")
        // §6.5: a reload at this size, another app's version (coordinated, in place) on disk to
        // the screen, once iCloud has the file as Nib opened it and Nib holds it. Written as Nib's
        // pause went in (iCloud uploading again), and the file removed at the end under that pause,
        // it crashed iCloud's file provider (2026-10-02, 13:25:29: its pause handler, §8 M2).
        _ = await waitFor(30) { document.held && isSynced(document) }
        let changed = text + "## Another app's line \(marker)\n"
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { target in
            try? Data(changed.utf8).write(to: target)
        }
        let written = Date()
        // The text storage's own string: `view.string` copies all 2.4 MB, a thousand times a second.
        let reloaded = await timed(10) { view.textStorage?.mutableString.hasSuffix("## Another app's line \(marker)\n") == true } != nil
        let reload = Date().timeIntervalSince(written)
        log.line("MEASURED a reload at 2.4 MB (another app's version, on disk to the screen): \(reloaded ? "\(Int(reload * 1000)) ms" : "not within 10 s") · target ≤ 100 ms · \(reloaded && reload <= 0.1 ? "met" : "NOT MET")")
        let end = (view.string as NSString).length   // longer now, by another app's line
        view.setSelectedRange(NSRange(location: end, length: 0))
        var slowest = 0.0
        for character in "## Typed \(marker)\n" {
            let start = Date()
            view.insertText(String(character), replacementRange: view.selectedRange())
            slowest = max(slowest, Date().timeIntervalSince(start))
            try? await Task.sleep(for: .milliseconds(30))
        }
        let stopped = Date()
        let typed = (view.string as NSString).range(of: "## Typed \(marker)").location
        let colored = await waitFor(5) { drawnColor(view, at: typed + 3) == yellow }
        log.check(colored, "a heading typed at the end: colored \(Int(Date().timeIntervalSince(stopped) * 1000)) ms after typing stopped")
        log.check(slowest < 0.05, "the slowest keystroke took \(String(format: "%.1f", slowest * 1000)) ms on the main thread")
        // LN, COL counted on from the last place, through typing and an edit above the caret.
        func counted(_ location: Int) -> (Int, Int) {
            let ns = view.string as NSString, before = ns.substring(to: location)
            let line = before.components(separatedBy: "\n").count
            return (line, location - ((before as NSString).range(of: "\n", options: .backwards).location == NSNotFound ? 0 : (before as NSString).range(of: "\n", options: .backwards).location + 1) + 1)
        }
        let caret = view.selectedRange().location
        log.check(document.cursor == counted(caret), "the strip's LN, COL after typing: \(document.cursor) (counted \(counted(caret)))")
        view.textStorage?.replaceCharacters(in: NSRange(location: 10, length: 0), with: "\n\n")   // above the caret, not typed
        let moved = view.selectedRange().location
        log.check(document.editor.position(of: moved) == counted(moved), "and after an edit above the caret: \(document.editor.position(of: moved)) (counted \(counted(moved)))")
        view.window?.performClose(nil)
        // Closed and handed back to iCloud, and only then removed (the defer): a document leaves
        // the list as its closing begins, and the file removed then was left paused (2026-10-01).
        _ = await waitFor(20) { Documents.existing(for: url) == nil && !document.held }
    }

    /// What Nib writes, and which of its code writes it (PRD §8, the disk-writes report of
    /// 2026-10-02): a generated Markdown file in the test folder (2.4 MB, or -NibWritesSize bytes),
    /// opened, typed in at its end and then near its top as a person types (a gap after each word,
    /// a longer one after every fourth, a pause after each sentence), left alone a minute, its
    /// note checked as when Nib comes forward, a version from another Mac taken in (its note, then
    /// the file, as a fetch puts it there) and typed after, and closed, as a quit closes each file. For each: this process's writes as
    /// the kernel counts them (logical, what the disk-writes limit counts, and bytes to disk),
    /// Nib's writers' share (NibSync's `WriteMeter`), and the footprint. The test's own writes
    /// (the file, the other Mac's version and note) are counted apart. Six to eleven minutes, so
    /// not in the suite: `scripts/run-writes.sh`.
    static func writesScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        await waitSynced(Documents.scratch, 30)
        let wanted = NibDefaults.store.integer(forKey: "NibWritesSize") > 0 ? NibDefaults.store.integer(forKey: "NibWritesSize") : 2_400_000
        let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("writes-\(marker).md")
        var text = "# Writes \(marker)\n", n = 0
        while text.utf8.count < wanted {
            n += 1
            switch n % 200 {
            case 0: text += "```bash\nrsync -av --progress ./dist/ me@seedbox:~/www/ && echo \"done \(n)\"\n```\n"
            case 50: text += "## Notes for \(n)\n"
            default:
                if n % 25 == 0 { text += String(repeating: "A long email paragraph that wraps, pasted from the thread about item \(n), ", count: 5) + "\n" }
                else if n % 3 == 0 { text += "- item \(n) with `code` and **bold** text\n" }
                else { text += "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
            }
        }
        defer {
            WriteMeter.counting = false
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Announcement.url(for: url))
            try? FileManager.default.removeItem(at: History(root: NibPaths.support.appendingPathComponent("History"), path: url.path).directory)
            for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(url)
        }
        func size(_ bytes: UInt64) -> String {
            bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(Int((Double(bytes) / 1_000).rounded())) KB"
        }
        // The test's own writes, kept out of Nib's: its file, the other Mac's version, the note.
        var own: (logical: UInt64, disk: UInt64) = (0, 0)
        func test(_ write: () -> Void) {
            WriteMeter.counting = false
            let before = WriteMeter.usage()
            write()
            let after = WriteMeter.usage()
            own.logical += after.logical &- before.logical
            own.disk += after.disk &- before.disk
            WriteMeter.counting = true
        }
        func inPlace(_ data: Data, at target: URL) {   // fsynced, so its bytes to disk land inside `test`
            guard let handle = try? FileHandle(forWritingTo: target) else { try? data.write(to: target); return }
            try? handle.write(contentsOf: data)
            try? handle.truncate(atOffset: UInt64(data.count))
            try? handle.synchronize()
            try? handle.close()
        }
        var last = WriteMeter.usage(), started = Date()
        var phases: [(name: String, tallies: [String: WriteMeter.Tally], logical: UInt64)] = []
        func measured(_ phase: String) {
            let now = WriteMeter.usage(), tallies = WriteMeter.take()
            let logical = now.logical &- last.logical &- own.logical, disk = now.disk &- last.disk &- min(own.disk, now.disk &- last.disk)
            let nib = tallies.values.reduce(UInt64(0)) { $0 + $1.logical }
            let each = tallies.sorted { $0.value.logical > $1.value.logical }
                .map { "\($0.key) \($0.value.writes)× \(size(UInt64($0.value.bytes))) (\(size($0.value.logical)))" }
            log.line("MEASURED writes · \(phase), \(Int(Date().timeIntervalSince(started).rounded())) s: \(size(logical)) logical (as the disk-writes report counts), \(size(disk)) to disk · Rune's writers \(size(nib)): \(each.isEmpty ? "none" : each.joined(separator: ", "))"
                     + (own.logical > 0 ? " · the test's own \(size(own.logical)), not counted" : "") + " · footprint \(size(now.footprint)), highest \(size(now.peak))")
            phases.append((phase, tallies, logical))
            last = now
            own = (0, 0)
            started = Date()
        }
        /// Saved, uploaded, and this Mac's receipt written (at most every 5 s), then a moment more.
        /// A save after one that wrote 2.4 MB waits 30 s (`SaveSchedule.rate`).
        func settled(_ document: Document) async {
            _ = await waitFor(45) { !document.dirty && isSynced(document) }
            try? await Task.sleep(for: .seconds(7))
        }
        /// As a person types: 40 ms a key, 120 ms after a word, 400 ms after every fourth (the
        /// journal writes 250 ms into a pause), 1.5 s after a sentence (a save comes 1 s into one).
        func typeLikeAPerson(_ document: Document, sentences: Int, at start: Int) async {
            let view = document.editor.textView
            var at = start
            for sentence in 1...sentences {
                let words = "Sentence \(sentence) of the writes test, typed a word at a time with pauses.".split(separator: " ")
                for (index, word) in words.enumerated() {
                    for character in word + (index == words.count - 1 ? "\n" : " ") {
                        view.setSelectedRange(NSRange(location: at, length: 0))
                        view.insertText(String(character), replacementRange: view.selectedRange())
                        at += (String(character) as NSString).length
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    try? await Task.sleep(for: .milliseconds(index % 4 == 3 ? 400 : 120))
                }
                try? await Task.sleep(for: .milliseconds(1_500))
            }
        }
        func holdsTheBuffer(_ document: Document) -> Bool {
            (try? Data(contentsOf: url)) == TextFile.encode(document.editor.textView.string, as: document.format)
        }

        test { try? Data(text.utf8).write(to: url, options: .atomic) }
        WriteMeter.counting = true
        _ = WriteMeter.take()
        last = WriteMeter.usage()
        own = (0, 0)
        started = Date()
        AppDelegate.openFile(url)
        _ = await waitFor(20) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        _ = await waitFor(30) { document.held && isSynced(document) }
        try? await Task.sleep(for: .seconds(7))
        log.line("a \(size(UInt64(text.utf8.count))) Markdown file, \(n) lines, open: held \(document.held), \(document.state.line)")
        measured("opened, held and synced")

        let view = document.editor.textView
        await typeLikeAPerson(document, sentences: 12, at: (view.string as NSString).length)
        await settled(document)
        log.check(holdsTheBuffer(document), "typed at the end: the file holds exactly the buffer")
        measured("typing at the end, 12 sentences")

        let top = (view.string as NSString).range(of: "\n").location + 1
        await typeLikeAPerson(document, sentences: 12, at: top)
        await settled(document)
        log.check(holdsTheBuffer(document), "typed near the top: the file holds exactly the buffer")
        measured("typing near the top, 12 sentences")

        var reads = document.noteReads
        try? await Task.sleep(for: .seconds(60))
        log.line("idle: \(document.noteReads.fresh - reads.fresh) fresh note reads, \(document.noteReads.local - reads.local) local")
        measured("idle a minute after typing (in the background, as Rune mostly is)")

        // As Nib comes forward: the note read fresh from the server (evicted, downloaded again),
        // with its upload long done. That eviction set off another, and so on for good (2026-10-02).
        reads = document.noteReads
        await document.checkAnnouncement(reason: "activated")
        try? await Task.sleep(for: .seconds(30))
        let fresh = document.noteReads.fresh - reads.fresh, local = document.noteReads.local - reads.local
        log.check(fresh == 1 && local <= 3, "a note check as at activation: \(fresh) fresh read\(fresh == 1 ? "" : "s") and \(local) of the note as it was here in 30 s after it, then none")
        measured("a note check as at activation, and 30 s after")

        // Another Mac's version, as `merge`'s: its note first, then the file in place.
        if let base = document.debugSnapshot.uploadedSHA {
            let theirs = TextFile.encode(view.string + "A paragraph typed on the other Mac \(marker).\n", as: document.format)
            let note = Announcement(sha256: Digest.sha256(theirs), parent: base, device: "Test Mac", size: theirs.count)
            test { try? note.write(for: url) }
            try? await Task.sleep(for: .seconds(3))
            test { inPlace(theirs, at: url) }
            let taken = await waitFor(15) { view.textStorage?.mutableString.hasSuffix("on the other Mac \(marker).\n") == true }
            log.check(taken, "the other Mac's version taken in (\(document.state.line))")
            await typeLikeAPerson(document, sentences: 2, at: (view.string as NSString).length)
            await settled(document)
            measured("another Mac's version taken in, two sentences typed after it")
        } else {
            log.check(false, "nothing uploaded to take another Mac's version onto (\(document.state.line))")
        }

        view.window?.performClose(nil)
        let closed = await waitFor(30) { Documents.existing(for: url) == nil && !document.held }
        try? await Task.sleep(for: .seconds(2))
        log.check(closed, "closed and handed back to iCloud")
        measured("closed (what a quit does for each file)")

        // Per save, typing at the end: the file's own share (only what changed) and the rest.
        if let end = phases.first(where: { $0.name.hasPrefix("typing at the end") }) {
            let saves = end.tallies["file"]?.writes ?? 0, file = end.tallies["file"]?.bytes ?? 0
            log.check(saves > 0 && file / max(saves, 1) < 65_536, "typing at the end: \(saves) saves wrote \(size(UInt64(file))) of the file, only what changed")
            let snapshots = phases.filter { $0.name.hasPrefix("typing") }.reduce(0) { $0 + ($1.tallies["journal snapshot"]?.writes ?? 0) }
            log.check(snapshots <= 1, "the journal: \(snapshots) snapshot\(snapshots == 1 ? "" : "s") over both typing phases (as it started), not one a pause or a minute")
        }
    }

    /// The Sync Log window (SY13, A13): Window › Sync Log (⌥⌘L), newest first, following the
    /// log as it grows, searchable by SHA-256 and by file (the strip's Show Sync Log), filtered.
    static func syncLogScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let model = SyncLogModel.shared
        let menu = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
        let item = menu?.items.first { $0.title == "Sync Log" }
        log.check(item?.keyEquivalent == "l" && item?.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .option],
                  "Window › Sync Log, ⌥⌘L")
        if let menu, let index = menu.items.firstIndex(where: { $0.title == "Sync Log" }) { menu.performActionForItem(at: index) }
        func window() -> NSWindow? { NSApp.windows.first { $0.title == "Sync Log" && $0.isVisible } }
        let opened = await waitFor(5) { window() != nil && model.loaded }
        log.check(opened && !model.rows.isEmpty, "it opens on this Mac's log (\(model.rows.count) events)")
        // Edit › Find… (⌘F) with it in front: its search field. It went to the text commands, and
        // nothing here took it (the QA review's §5).
        ScenarioFocus.take()
        window()?.makeKeyAndOrderFront(nil)
        let inFront = await waitFor(5) { window() != nil && NSApp.keyWindow === window() }
        let findMenu = NSApp.mainMenu?.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Find" }?.submenu
        if let findMenu, let index = findMenu.items.firstIndex(where: { $0.title == "Find…" }) { findMenu.performActionForItem(at: index) }
        let searching = await waitFor(3) { ((window()?.firstResponder as? NSTextView)?.delegate as? NSSearchField) != nil }
        ScenarioFocus.giveBackNow()
        log.check(searching || !inFront, "Edit › Find… with it in front: the caret in its search field (\(searching ? "there" : inFront ? "not there" : "Rune not in front, not checked"))")
        let wholeReads = model.wholeReads
        let shown = model.shown
        log.check(zip(shown, shown.dropFirst()).allSatisfy { $0.time >= $1.time }, "newest first")

        let start = Date().addingTimeInterval(-1)
        await type("\n- sync log \(marker)\n", into: document)
        let arrived = await waitFor(10) { model.rows.contains { $0.event.event == "save" && $0.event.path == document.url.path && $0.time >= start } }
        log.check(arrived && model.shown.first?.time ?? .distantPast >= start, "a save made while it's open appears, at the top")
        // Read as the lines come, not the whole log again (the QA review's F33).
        log.check(model.wholeReads == wholeReads, "and only the new lines were read, not the whole log again (\(model.wholeReads - wholeReads) whole reads)")
        if let sha = model.rows.last(where: { $0.event.event == "save" && $0.event.path == document.url.path })?.event.sha256 {
            model.search = String(sha.prefix(10))
            let found = model.shown
            log.check(!found.isEmpty && found.allSatisfy { $0.event.sha256?.hasPrefix(String(sha.prefix(10))) == true },
                      "search by SHA-256: \(found.count) line\(found.count == 1 ? "" : "s") with \(sha.prefix(10))…")
        }
        model.search = document.url.lastPathComponent   // what the strip's Show Sync Log does
        let file = model.shown
        log.check(!file.isEmpty && file.allSatisfy { $0.name == document.url.lastPathComponent }, "on one file: \(file.count) lines, all \(document.url.lastPathComponent)")
        model.search = ""
        model.filter = .problems
        let problems = model.shown
        log.check(problems.allSatisfy { $0.event.needsLook }, "Problems: \(problems.count) lines, all conflicts, refusals or failures")
        model.filter = .all
        try? await Task.sleep(for: .milliseconds(500))
        if let window = window(), let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-synclog.png"))
        }
        window()?.close()
        // Closed, it reads nothing and keeps nothing as lines are added (F33: every line read the
        // whole log for the rest of the session).
        _ = await waitFor(5) { window() == nil && model.rows.isEmpty }
        let readsClosed = model.wholeReads
        await type("- after the sync log closed \(marker)\n", into: document)
        await document.flush(reason: "test")
        try? await Task.sleep(for: .milliseconds(800))
        log.check(model.rows.isEmpty && model.wholeReads == readsClosed, "closed, it reads nothing as lines are added, and keeps none (\(model.rows.count) rows)")
        // Show History for a line's file: open, its History; not open, a way to open it; gone, so
        // said (the QA review's F35: "Open the file to see its History.", with no way to).
        let elsewhere = URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("elsewhere-\(marker).md")
        try? Data("# Elsewhere\n".utf8).write(to: elsewhere)
        let gone = elsewhere.deletingLastPathComponent().appendingPathComponent("gone-\(marker).md")
        let views = [HistoryWindow.shown(url: document.url, document: document), HistoryWindow.shown(url: elsewhere, document: nil), HistoryWindow.shown(url: gone, document: nil)]
        try? FileManager.default.removeItem(at: elsewhere)
        log.check(views == [.history, .notOpen(elsewhere.lastPathComponent), .gone(gone.lastPathComponent)],
                  "Show History: its History for an open file, Open for one that isn't, and gone for one that's gone")
    }

    /// History (SY13): each saved version is kept; Revert To puts one back as an edit, and the
    /// version it replaced can be put back in turn.
    /// History (open question 22): of two saves in one span, only the newer goes in, at the
    /// span's end, with the time it was saved; the one let go still counts as seen here
    /// (receipts); Revert To goes in at once; the save Nib quits with goes in (`history-closed`).
    /// Find in History (SY18): a paragraph kept in History, then deleted; Find comes up empty in
    /// the text and names the version that has it; the History window opens on that version with
    /// the match shown; Copy Paragraph puts it on the clipboard; a search that's nowhere says so.
    static func findHistoryScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        TestHarness.historySpan = 5
        await waitReady(document)
        await waitSynced(document, 20)
        let view = document.editor.textView, find = document.editor.find
        let paragraph = "- packing note \(marker): the spare charger is in the blue pouch\n"
        await type("\n" + paragraph, into: document)
        let kept = await waitFor(15) { document.history.entries().contains { text(document, $0).contains("blue pouch") && text(document, $0).contains(marker) } }
        log.check(kept, "the paragraph is in a version History keeps")
        // Deleted, and saved without it.
        let range = (view.string as NSString).range(of: paragraph)
        view.setSelectedRange(range)
        view.insertText("", replacementRange: range)
        await endOfEvent(view)
        let gone = await waitFor(10) { !fileText(document).contains("blue pouch") && !document.dirty }
        _ = await waitFor(5) { document.historyEntries.map(\.sha256) == document.history.entries().map(\.sha256) }

        find.open(replace: false)
        find.query = "spare charger is in the blue"
        let looked = await waitFor(8) { if case .found = find.inHistory { return true } else { return false } }
        let label = find.countLabel
        log.check(gone && looked && label.hasPrefix("NO MATCHES · IN HISTORY: ") && find.matches.isEmpty,
                  "deleted, Find has no matches in the text and names the version that has it (“\(label)”)")
        guard find.historyFocus() != nil else { find.close(); return }

        // As the bar's click: the History window, on that version, the match shown.
        let saved = savePasteboard()
        defer { restorePasteboard(saved) }
        find.showInHistory()   // what the bar's found line does when clicked
        func historyWindow() -> NSWindow? { NSApp.windows.first { $0.title.hasPrefix("History") && $0.isVisible } }
        func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
            guard let view else { return [] }
            return (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
        }
        let opened = await waitFor(5) { historyWindow() != nil }
        let preview = await waitFor(5) {
            views(NSTextView.self, in: historyWindow()?.contentView).contains {
                guard $0.string.contains("blue pouch"), let at = ($0.string as NSString).range(of: "spare charger is in the blue").nilIfMissing,
                      let place = $0.placeRect(at: at.location) else { return false }
                return $0.visibleRect.intersects(place)
            }
        }
        let texts = views(NSTextView.self, in: historyWindow()?.contentView)
        log.check(opened && preview, "the History window opens on that version, the match in view (window \(opened), \(texts.count) text view\(texts.count == 1 ? "" : "s"), \(texts.first.map { "\($0.string.count) characters" } ?? "none"))")
        if let window = historyWindow(), let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("findhistory.png"))
        }
        // Copy Paragraph's work, on the window's text and the match it shows (SwiftUI's buttons
        // can't be pressed from here: it builds their accessibility only for an assistive app).
        NSPasteboard.general.clearContents()
        let shown = views(NSTextView.self, in: historyWindow()?.contentView).first
        let said = shown.flatMap { view in (view.string as NSString).range(of: "spare charger is in the blue").nilIfMissing.flatMap { HistoryView.copyParagraph(in: view.string, at: $0) } }
        let copied = NSPasteboard.general.string(forType: .string) == paragraph.trimmingCharacters(in: .newlines)
        log.check(copied && said == "Copied the paragraph, 1 line. ⌘V puts it in the text.",
                  "Copy Paragraph puts the paragraph round the match on the clipboard (“\(NSPasteboard.general.string(forType: .string) ?? "nothing")”; \(said ?? "nothing said"))")
        historyWindow()?.performClose(nil)
        let cleared = await waitFor(3) { historyWindow() == nil && document.historyFocus == nil }
        log.check(cleared, "closing the History window lets the search go: History opened another way shows none")

        // A search that's nowhere.
        find.query = "not anywhere \(marker) at all"
        let nowhere = await waitFor(8) { find.inHistory == .nowhere }
        log.check(nowhere && find.countLabel == "NO MATCHES · NOT IN HISTORY EITHER", "a search that's nowhere: “\(find.countLabel)”")
        // Short searches and the selection don't look further.
        find.query = "zq"
        try? await Task.sleep(for: .milliseconds(900))
        log.check(find.inHistory == .none && find.countLabel == "NO MATCHES", "under 3 characters, History isn't searched (“\(find.countLabel)”)")
        find.close()
    }

    /// Changes since the last commit (ED12): a repository made in the test folder outside iCloud
    /// (never a `.git` in iCloud Drive); a committed file opened shows no marks; a changed, an added
    /// and a deleted line are marked in the gutter and counted in the HUD's line; a commit made by
    /// git outside Rune clears them; a file git doesn't track, and one outside any repository.
    static func gitMarksScenario(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        guard GitRepo.installed else { log.check(false, "git installed (the developer tools)"); return }
        let repo = ScratchLocation.localTestFolder.appendingPathComponent("git-\(marker)", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func sh(_ command: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        let file = repo.appendingPathComponent("notes.md"), other = repo.appendingPathComponent("draft.md")
        let outside = ScratchLocation.localTestFolder.appendingPathComponent("plain-\(marker).md")
        defer {
            for url in [file, other, outside] { Documents.existing(for: url)?.editor.textView.window?.performClose(nil) }
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: outside)
        }
        try? Data("one \(marker)\ntwo\nthree\nfour\nfive\n".utf8).write(to: file)
        sh("git init -q -b main && git config user.email test@example.com && git config user.name Test && git add notes.md && git commit -q -m first")

        AppDelegate.openFile(file)
        _ = await waitFor(10) { Documents.existing(for: file)?.ready == true }
        guard let document = Documents.existing(for: file) else { log.check(false, "the committed file opened"); return }
        let clean = await waitFor(8) { document.git.status == .tracked(branch: "main") }
        log.check(clean && document.git.changes.isEmpty && document.git.hudLine == "GIT · MAIN · NO CHANGES SINCE THE LAST COMMIT",
                  "a committed file, as committed: no marks (“\(document.git.hudLine ?? "no git line")”)")

        // A changed line, an added one, a deleted one.
        let view = document.editor.textView
        func replace(_ old: String, _ new: String) {
            let range = (view.string as NSString).range(of: old)
            guard range.location != NSNotFound else { return }
            view.setSelectedRange(range)
            view.insertText(new, replacementRange: range)
        }
        replace("two\n", "TWO\n")
        replace("three\n", "three\nadded line\n")
        replace("five\n", "")
        await endOfEvent(view)
        let marked = await waitFor(5) { document.git.changes.modified == 1 && document.git.changes.added == 1 && document.git.changes.deleted == 1 }
        document.editor.ruler?.display()
        let drawn = document.editor.ruler?.drawnMarks ?? [:]
        log.check(marked && drawn[1] == "modified" && drawn[3] == "added" && drawn.values.contains("deleted"),
                  "a changed, an added and a deleted line, marked in the gutter (\(drawn.sorted { $0.key < $1.key }.map { "\($0.key + 1): \($0.value)" }.joined(separator: ", "))) and in the HUD (“\(document.git.hudLine ?? "")”)")
        log.check(document.git.hudLine == "GIT · MAIN · 1 CHANGED · 1 ADDED · 1 DELETED", "the HUD's line: “\(document.git.hudLine ?? "none")”")
        document.toggleSyncDetails()   // the HUD open, its git line in the picture
        try? await Task.sleep(for: .milliseconds(700))
        if let window = view.window, let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("gitmarks.png"))
        }
        document.toggleSyncDetails()

        // A click on a mark: the change and its committed lines, COPY and REVERT (one ⌘Z step).
        // The text now: "one…", "TWO", "three", "added line", "four"; "five" deleted at the end.
        let saved = savePasteboard()
        func click(line: Int) -> Bool {
            guard let ruler = document.editor.ruler, let window = ruler.window else { return false }
            var y: CGFloat = 0
            while y < ruler.bounds.height, ruler.line(atY: y)?.0 != line { y += 2 }
            guard y < ruler.bounds.height else { return false }
            let point = ruler.convert(NSPoint(x: ruler.bounds.width - 5, y: y + 3), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            ruler.mouseDown(with: event)
            return true
        }
        let clicked = click(line: 1)
        let shown = await waitFor(2) { ChangePanel.isShown }
        log.check(clicked && shown && ChangePanel.current == LineChanges.Hunk(lines: 1..<2, committed: ["two"]),
                  "a click on the changed line's mark shows the change: \(ChangePanel.current.map { "lines \($0.lines), committed \($0.committed)" } ?? "nothing")")
        try? await Task.sleep(for: .milliseconds(400))
        if let panel = NSApp.windows.first(where: { $0.isVisible && String(describing: Swift.type(of: $0)).contains("Popover") }), let frame = panel.contentView,
           let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("changepanel.png"))
        }
        ChangePanel.press("COPY", in: document)
        log.check(NSPasteboard.general.string(forType: .string) == "two\n" && !ChangePanel.isShown, "COPY: the committed line on the clipboard, the panel closed")
        restorePasteboard(saved)
        _ = click(line: 1)
        _ = await waitFor(2) { ChangePanel.isShown }
        ChangePanel.press("REVERT", in: document)
        let lines = { view.string.components(separatedBy: "\n") }
        let reverted = lines()[1] == "two" && document.git.changes.modified == 0 && document.git.changes.added == 1 && document.git.changes.deleted == 1
        log.check(reverted && view.undoManager?.undoActionName == "Revert Change",
                  "REVERT: the committed line back, its mark gone, the others kept (\(document.git.hudLine ?? "")); Edit › Undo Revert Change")
        await endOfEvent(view)
        view.undoManager?.undo()
        _ = document.git.changesNow()
        log.check(lines()[1] == "TWO" && document.git.changes.modified == 1, "⌘Z takes the revert back: “\(lines()[1])”")

        // Next Change and Previous Change, round the ends; Revert Change at the caret.
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var visited: [Int] = []
        for _ in 0..<4 {
            document.git.go(forward: true)
            visited.append(document.editor.lineIndex.line(at: view.selectedRange().location))
        }
        document.git.go(forward: false)
        let back = document.editor.lineIndex.line(at: view.selectedRange().location)
        log.check(visited == [2, 4, 6, 2] && back == 6,
                  "Next Change: lines 2, 4, then the end (where “five” was), round to 2; Previous Change round to the end: \(visited), back \(back)")
        view.setSelectedRange(NSRange(location: document.editor.lineIndex.start(ofLine: 4) ?? 0, length: 0))
        await endOfEvent(view)
        document.git.revertAtCaret()
        await endOfEvent(view)
        let added = !view.string.contains("added line") && document.git.changes.added == 0
        if let last = document.git.changesNow()?.hunks.last { document.git.revert(last) }
        await endOfEvent(view)
        let committedNow = view.string == "one \(marker)\nTWO\nthree\nfour\nfive\n"
        log.check(added && committedNow && document.git.changes.deleted == 0,
                  "Revert Change on the added line takes it out; on the end's notch, “five” back: \(view.string.debugDescription)")
        view.undoManager?.undo()
        await endOfEvent(view)
        view.undoManager?.undo()
        await endOfEvent(view)
        _ = document.git.changesNow()
        log.check(document.git.changes.modified == 1 && document.git.changes.added == 1 && document.git.changes.deleted == 1,
                  "and two ⌘Z put both back (\(document.git.hudLine ?? ""))")

        // Committed by git outside Rune: the marks go.
        await document.flush(reason: "test")
        _ = await waitFor(5) { !document.dirty }
        sh("git commit -q -am second")
        let cleared = await waitFor(8) { document.git.changes.isEmpty && document.git.status == .tracked(branch: "main") }
        log.check(cleared, "committed outside Rune: the marks go (“\(document.git.hudLine ?? "")”)")

        // A file git doesn't track, and one outside any repository.
        try? Data("not added \(marker)\n".utf8).write(to: other)
        try? Data("no repository \(marker)\n".utf8).write(to: outside)
        AppDelegate.openFile(other)
        AppDelegate.openFile(outside)
        _ = await waitFor(10) { Documents.existing(for: other)?.ready == true && Documents.existing(for: outside)?.ready == true }
        let untracked = await waitFor(8) { Documents.existing(for: other)?.git.status == .untracked(branch: "main") }
        let plainFile = Documents.existing(for: outside)
        try? await Task.sleep(for: .milliseconds(500))
        log.check(untracked && Documents.existing(for: other)?.git.hudLine == "GIT · MAIN · NOT TRACKED YET"
                    && Documents.existing(for: other)?.git.changes.isEmpty == true
                    && plainFile?.git.status == GitMarks.Status.none && plainFile?.git.hudLine == nil,
                  "a file git doesn't track says so, with no marks; outside a repository, nothing")
    }

    static func historyScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        TestHarness.historySpan = 5
        await waitReady(document)
        await waitSynced(document, 20)
        func fileSHA() -> String { Digest.sha256((try? Data(contentsOf: document.url)) ?? Data()) }
        await type("\n- history one \(marker)\n", into: document)
        _ = await waitFor(10) { fileText(document).contains("history one \(marker)") && !document.dirty }
        let one = fileSHA(), typedTwo = Date()
        await type("- history two \(marker)\n", into: document)
        _ = await waitFor(10) { fileText(document).contains("history two \(marker)") && !document.dirty }
        let two = fileSHA(), savedTwo = Date()
        let waited = !document.history.entries().contains { $0.sha256 == one || $0.sha256 == two }
        let kept = await waitFor(10) { document.history.entries().contains { $0.sha256 == two } }
        let entries = document.history.entries()
        log.check(waited && kept && !entries.contains { $0.sha256 == one },
                  "two saves in one span: only the newer went into History, at the span's end (\(entries.count) versions)")
        let entry = entries.last { $0.sha256 == two }
        // Between typing it and seeing it in the file (a coordinated read can wait behind the upload).
        log.check(entry.map { $0.time >= typedTwo && $0.time <= savedTwo } == true,
                  "with the time it was saved (\(entry.map { String(format: "%.1f", $0.time.timeIntervalSince(typedTwo)) } ?? "?") s after typing it began), not the span's end")
        log.check(document.history.has(one), "the save let go still counts as one this Mac had (receipts)")
        let opened = entries.last { $0.source == "opened" }
        log.check(opened != nil, "the version as opened is in History")
        guard let opened, let entry else { return }
        document.restore(opened)
        let back = await waitFor(10) { !fileText(document).contains("history one \(marker)") && !document.dirty }
        // Named with its day, as History names it (the QA review's F20: the time alone).
        log.check(back && document.notice?.contains("BACK TO THE VERSION FROM TODAY ") == true, "Revert To: the earlier version, in the buffer and the file, named with its day (\(document.notice ?? "no notice"))")
        let atOnce = await waitFor(3) { document.history.entries().last.map { !text(document, $0).contains("history one \(marker)") && $0.time > savedTwo } == true }
        // Named for what it is, not "saved" (the QA review's F55).
        let restoredAs = document.history.entries().last?.source ?? ""
        log.check(atOnce && restoredAs.hasPrefix("restored from Today "), "and it went into History at once, not at a span's end, as “\(restoredAs)”")
        // Shown with a capital, "iCloud" kept (F80: "saved · 588 bytes").
        log.check(HistoryView.source("saved") == "Saved" && HistoryView.source(restoredAs).hasPrefix("Restored from Today ")
                  && HistoryView.source("iCloud conflict version from Air") == "iCloud conflict version from Air", "History shows its sources with a capital")
        // What Revert To and the History window show is read off the main thread, and follows (F57).
        let mirrored = await waitFor(3) { document.historyEntries.map(\.sha256) == document.history.entries().map(\.sha256) }
        log.check(mirrored, "Revert To's and the History window's list follows History (\(document.historyEntries.count) versions), read off the main thread")
        document.restore(entry)
        let again = await waitFor(10) { fileText(document).contains("history two \(marker)") }
        log.check(again, "and the version it replaced came back from History")
        // The last save, waiting for its span's end when Nib quits: in History before Nib goes.
        TestHarness.historySpan = 600
        await type("- history closed \(marker)\n", into: document)
        _ = await waitFor(10) { fileText(document).contains("history closed \(marker)") && !document.dirty }
        log.check(!document.history.entries().contains { text(document, $0).contains("history closed \(marker)") },
                  "the last save waits for its span's end (history-closed checks it went in at the quit)")
    }

    /// After `history`: the save Nib quit with, waiting for its span's end, went into History as it
    /// quit, though the quit was cut off by its watchdog before iCloud took the file back.
    static func historyClosed(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        let entries = document.history.entries()
        let closed = entries.last { ["saved", "closed"].contains($0.source) && text(document, $0).contains("history closed \(marker)") }
        log.check(closed != nil, "the save Rune quit with is in History, as saved (\(entries.suffix(3).map(\.source).joined(separator: ", ")))")
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
    /// SY12's last question, on two Macs (PRD §4.8 E, §4.9 8-10): b, as Finder or another app
    /// on the other Mac, moves one of a's open (held) test files to the Trash, deletes another,
    /// renames a third, and renames the folder of a fourth; a says when each leaves its place
    /// here, comes at its new one, and what Nib shows, left alone and then come forward. A probe:
    /// a FAIL is what isn't handled yet, and what it finds goes in PRD §8.
    static func twoMacRemote(_ log: HarnessLog, _ marker: String) async {
        let defaults = NibDefaults.store
        let role = defaults.string(forKey: "NibRole") ?? "a"
        let t0 = defaults.double(forKey: "NibAt")
        func until(_ offset: Double) async {
            let wait = t0 + offset - Date().timeIntervalSince1970
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        func since(_ offset: Double) -> String { String(format: "%+.1f s", Date().timeIntervalSince1970 - (t0 + offset)) }
        let test = ScratchLocation.url.deletingLastPathComponent()
        let folder = test.appendingPathComponent("remote-folder-\(marker)", isDirectory: true)
        let movedFolder = test.appendingPathComponent("remote-folder-moved-\(marker)", isDirectory: true)
        let cases: [(name: String, url: URL, moved: URL?)] = [
            ("trashed", test.appendingPathComponent("remote-trash-\(marker).md"), nil),
            ("deleted", test.appendingPathComponent("remote-delete-\(marker).md"), nil),
            ("renamed", test.appendingPathComponent("remote-rename-\(marker).md"), test.appendingPathComponent("remote-renamed-\(marker).md")),
            ("folder renamed", folder.appendingPathComponent("inside-\(marker).md"), movedFolder.appendingPathComponent("inside-\(marker).md")),
        ]
        log.line("\(role): the remote probe · \(Int(t0 - Date().timeIntervalSince1970)) s to go")

        if role == "a" {
            await until(0)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for c in cases { try? Data("# \(c.name) \(marker)\n\nopen on a\n".utf8).write(to: c.url) }
            for c in cases { AppDelegate.openFile(c.url) }
            let held = await waitFor(55) { cases.allSatisfy { Documents.existing(for: $0.url)?.held == true } }
            log.line("a: the four files open\(held ? " and held" : ""): " + cases.map { "\($0.name) \(Documents.existing(for: $0.url)?.held == true ? "held" : "not held")" }.joined(separator: ", "))
            let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
            let before = events.read().count
            // From b's moves (+60) to +240, once a second: what changed, and when.
            var last: [String: String] = [:]
            func note(_ key: String, _ text: String) {
                guard last[key] != text else { return }
                last[key] = text
                log.line("a: \(key): \(since(60)) \(text)")
            }
            func nib(_ c: (name: String, url: URL, moved: URL?)) -> String {
                if let moved = c.moved, let follower = Documents.existing(for: moved) {
                    return "Rune has it open at its new place (\(follower.state.line.components(separatedBy: " · ").first ?? ""))"
                }
                guard let document = Documents.existing(for: c.url) else { return "Rune: no window for it" }
                if document.deleted { return "Rune: the deleted banner, \(document.iCloudOff ? "ICLOUD OFF" : document.deletedToTrash ? "IN THE TRASH" : "DELETED")" }
                return "Rune: \(document.state.line.components(separatedBy: " · ").first ?? "")"
            }
            await until(60)
            var cameForward = false
            while Date().timeIntervalSince1970 < t0 + 240 {
                if !cameForward, Date().timeIntervalSince1970 >= t0 + 150 {
                    cameForward = true
                    log.line("a: \(since(60)) coming forward: each file's window active, as if you looked at this Mac")
                    for c in cases { Documents.existing(for: c.url)?.becameActive() }
                }
                for c in cases {
                    note(c.name, FileManager.default.fileExists(atPath: c.url.path) ? "in its place on this Mac" : "gone from its place on this Mac")
                    if let moved = c.moved, FileManager.default.fileExists(atPath: moved.path) { note(c.name + ", new place", "at its new place on this Mac") }
                    note(c.name + ", Rune", nib(c))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            // What §4.8 E and SY12 ask (a probe: a FAIL is what isn't handled yet).
            log.check(Documents.existing(for: cases[0].url)?.deleted == true, "a: moved to the Trash on b: Rune shows the deleted banner (\(nib(cases[0])))")
            log.check(Documents.existing(for: cases[1].url)?.deleted == true, "a: deleted on b: Rune shows the deleted banner (\(nib(cases[1])))")
            log.check(cases[2].moved.flatMap { Documents.existing(for: $0) } != nil, "a: renamed on b: Rune follows it to its new name (\(nib(cases[2])))")
            log.check(cases[3].moved.flatMap { Documents.existing(for: $0) } != nil, "a: its folder renamed on b: Rune follows it (\(nib(cases[3])))")
            // This Mac's Sync Log for those files, in order.
            let paths = Set(cases.flatMap { [$0.url.path] + ($0.moved.map { [$0.path] } ?? []) })
            for event in events.read().dropFirst(before) where paths.contains(event.path) && !["receipt", "save", "upload"].contains(event.event) {
                log.line("a: log \(SyncState.clock.string(from: event.time)) \(URL(fileURLWithPath: event.path).lastPathComponent) \(event.event): \(event.detail ?? "")")
            }
            // Away again: closed (a deleted file's text stays in History), and what's left removed.
            for c in cases {
                for url in [c.url] + (c.moved.map { [$0] } ?? []) { Documents.existing(for: url)?.editor.textView.window?.performClose(nil) }
            }
            _ = await waitFor(20) { cases.allSatisfy { Documents.existing(for: $0.url) == nil && $0.moved.flatMap { Documents.existing(for: $0) } == nil } }
            for c in cases {
                for url in [c.url] + (c.moved.map { [$0] } ?? []) {
                    try? FileManager.default.removeItem(at: url)
                    for prefix in ["selection:", "syntax:", "siblings:"] { NibDefaults.store.removeObject(forKey: prefix + url.path) }
                    RecentFiles.shared.remove(url)
                    for item in ClosedItems.shared.items where item.path == url.path { ClosedItems.shared.forget(item) }
                }
            }
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: movedFolder)
        } else {
            await until(0)
            let here = await waitFor(55) { cases.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } }
            log.line("b: the four files are here: \(here)")
            await until(60)
            // As Finder does, each coordinated: to the Trash, deleted, renamed, the folder renamed.
            var inTrash: NSURL?
            do {
                try FileManager.default.trashItem(at: cases[0].url, resultingItemURL: &inTrash)
                log.line("b: \(since(60)) moved \(cases[0].url.lastPathComponent) to the Trash")
            } catch { log.line("b: \(since(60)) couldn't move it to the Trash: \(error.localizedDescription)") }
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: cases[1].url, options: .forDeleting, error: &error) { target in
                try? FileManager.default.removeItem(at: target)
            }
            log.line("b: \(since(60)) deleted \(cases[1].url.lastPathComponent)\(error.map { " (\($0.localizedDescription))" } ?? "")")
            for (source, target) in [(cases[2].url, cases[2].moved!), (folder, movedFolder)] {
                do {
                    try await CloudControl.within(20) { try FileCommands.coordinatedMove(source, to: target, caseOnly: false) }
                    log.line("b: \(since(60)) renamed \(source.lastPathComponent) to \(target.lastPathComponent)")
                } catch { log.line("b: \(since(60)) couldn't rename \(source.lastPathComponent): \(error.localizedDescription)") }
            }
            // After a has looked (+240) and closed them: this run's own things removed.
            await until(255)
            if let trashed = inTrash as URL? { try? FileManager.default.removeItem(at: trashed) }   // the test file it put in the Trash, only that
            try? FileManager.default.removeItem(at: cases[2].moved!)
            try? FileManager.default.removeItem(at: movedFolder)
            try? FileManager.default.removeItem(at: folder)
            log.line("b: \(since(60)) cleared away")
        }
    }

    static func twoMac(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        let defaults = NibDefaults.store
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
        // Delivery receipts (SY14): the other Mac says it has this very version.
        let delivered = await waitFor(max(5, t0 + 230 - Date().timeIntervalSince1970)) {
            document.otherMacs.contains { $0.delivery == .same && $0.device != document.device }
        }
        log.check(delivered, "\(role): the other Mac's receipt says it has this version (strip: \(document.statusLine); receipts: \(document.otherMacs.map { "\($0.device) \($0.delivery)" }.joined(separator: ", ")))")
        await until(235)
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
        if let name = NibDefaults.store.string(forKey: "NibSnapshotFile") {   // a file window, highlighted
            let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent(name)
            AppDelegate.openFile(url)
            _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window != nil }
            guard let file = Documents.existing(for: url), let window = file.editor.textView.window else { log.line("FAIL \(name) didn't open"); return }
            window.setFrame(NSRect(x: 80, y: 120, width: 820, height: 640), display: true)
            let end = NibDefaults.store.bool(forKey: "NibSnapshotEnd") ? (file.editor.textView.string as NSString).length : 0
            file.editor.textView.setSelectedRange(NSRange(location: end, length: 0))
            file.editor.textView.reveal(end)
            log.line("window \(window.windowNumber)")   // for `screencapture -l`: this window alone, even under others
            try? await Task.sleep(for: .milliseconds(1200))
            for (suffix, wait) in [("", 300), ("-later", 2000)] {
                try? await Task.sleep(for: .milliseconds(wait))
                if let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log.path).deletingLastPathComponent().appendingPathComponent("snapshot-\(name)\(suffix).png"))
                    log.line("rendered snapshot-\(name)\(suffix).png")
                }
            }
            window.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: url) == nil }
            return
        }
        if NibDefaults.store.bool(forKey: "NibSnapshotHistory") {   // the History window, as File › Revert To opens it
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
        if NibDefaults.store.bool(forKey: "NibSnapshotConflict") {   // the banner and a block (§5.4)
            sample = "## Email · Q4 vendor\nHi Sam, thanks for the quick turnaround.\n<<<<<<< \(document.device) · 10:42\nWe can ship on Friday if QA signs off.\n=======\nWe can ship Thursday.\n>>>>>>> Bill’s MacBook Air · 10:41\nAlso: invoice attached.\n"
        }
        let sampleRange = NSRange(location: (view.string as NSString).length, length: (sample as NSString).length)
        view.setSelectedRange(NSRange(location: sampleRange.location, length: 0))
        view.insertText(sample, replacementRange: view.selectedRange())
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: document.blocks.last.map { $0.first.location + 4 } ?? end - 20, length: 0))
        view.reveal(view.selectedRange().location)
        await waitSynced(document, 20)
        guard let window = view.window else { log.line("FAIL no window"); return }
        window.setFrame(NSRect(x: 80, y: 120, width: 760, height: 420), display: true)
        window.makeKeyAndOrderFront(nil)
        ScenarioFocus.take()
        view.reveal(document.blocks.last.map { NSMaxRange($0.range) + 30 } ?? view.selectedRange().location)
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

    // MARK: §6.5, measured

    /// The §6.5 targets Nib can measure itself, each a MEASURED line with its target (a Debug
    /// build: memory and times run higher than a release). Nothing fails for a missed target:
    /// §6.5 asks for each "met, or its gap written down". Idle memory, CPU and wakeups with the
    /// scratch window and without; Show Scratch's window side (the activation itself needs a real
    /// key press, which a scenario can't make); a new version on disk to the screen, coordinated
    /// and not; keystrokes on the main thread; a 5 MB JavaScript file and a 2.4 MB Markdown one
    /// opened, first shown and colored, then the 2.4 MB one reloaded, and a three-way merge at
    /// that size. The big files are untitled buffers, on this Mac only: made in iCloud Drive,
    /// big files leave iCloud's daemons slow for minutes (`bigfile` runs last for that).
    static func perfScenario(_ document: Document, _ log: HarnessLog, _ marker: String) async {
        await waitReady(document)
        await waitSynced(document, 30)
        var missing: [String] = []
        func measured(_ what: String, _ value: String, target: String, met: Bool?) {
            log.line("MEASURED \(what): \(value) · target \(target)\(met.map { $0 ? " · met" : " · NOT MET" } ?? "")")
        }
        func percentiles(_ values: [Double]) -> (p50: Double, p95: Double, max: Double) {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return (0, 0, 0) }
            return (sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)], sorted.last!)
        }
        func ms(_ seconds: Double) -> String { seconds < 0.01 ? String(format: "%.1f ms", seconds * 1000) : "\(Int((seconds * 1000).rounded())) ms" }

        // Idle: memory, CPU and wakeups, with the scratch window open and then with no windows.
        func idle(_ label: String, footprintTarget: Double) async {
            // Settled: launch's own work done first (History thinned, receipts read…). It tails off
            // over about 20 s (the `idle` scenario, 5 s slices: 0.63%, 0.10, 0.25, 0.03, 0.01…), so
            // two quiet slices in a row, under 0.1% each, up to a minute.
            var quiet = 0
            for _ in 0..<12 where quiet < 2 {
                let a = usage()
                try? await Task.sleep(for: .seconds(5))
                quiet = (usage().cpu - a.cpu) / 5 < 0.001 ? quiet + 1 : 0
            }
            let before = usage(), start = Date()
            try? await Task.sleep(for: .seconds(12))
            let after = usage(), seconds = Date().timeIntervalSince(start)
            let cpu = (after.cpu - before.cpu) / seconds * 100
            let wakeups = Double(after.wakeups - before.wakeups) / seconds
            let memory = footprint()
            measured("idle memory, \(label)", String(format: "%.1f MB", memory), target: "≤ \(Int(footprintTarget)) MB", met: memory <= footprintTarget)
            measured("idle CPU and wakeups, \(label)", String(format: "%.2f%% CPU, %.1f wakeups a second", cpu, wakeups), target: "0.0%, no timer wakeups", met: cpu < 0.05 && wakeups < 1)
        }
        // §6.5: ≤ 45 MB with a small scratch file, its window open or not (revised 2026-09-30).
        await idle("the scratch window open", footprintTarget: 45)
        AppDelegate.scratchWindow?.orderOut(nil)
        await idle("no windows", footprintTarget: 45)

        // Show Scratch: the window side, Nib in front (a few seconds with the focus).
        ScenarioFocus.take()
        _ = await waitFor(3) { NSApp.isActive }
        var shows: [Double] = []
        for _ in 0..<12 {
            AppDelegate.scratchWindow?.orderOut(nil)
            try? await Task.sleep(for: .milliseconds(150))
            let started = Date()
            AppDelegate.showScratch()
            if let _ = await timed(2, { AppDelegate.scratchWindow?.isKeyWindow == true && AppDelegate.scratchWindow?.firstResponder === document.editor.textView }) {
                AppDelegate.scratchWindow?.displayIfNeeded()
                shows.append(Date().timeIntervalSince(started))
            }
        }
        ScenarioFocus.giveBackNow()
        if shows.isEmpty { missing.append("Show Scratch") } else {
            let p = percentiles(Array(shows.dropFirst(2)))   // the first two warm up
            measured("Show Scratch to caret ready, the window side (Rune in front; macOS's activation not included)",
                     "p50 \(ms(p.p50)), p95 \(ms(p.p95)), max \(ms(p.max)) (\(shows.count - 2) shows)", target: "≤ 50 ms p95", met: p.p95 <= 0.05)
        }

        // A new version on disk to the screen: a small test file, held, written by "another app".
        let folder = document.url.deletingLastPathComponent()
        let small = folder.appendingPathComponent("perf-\(marker).md")
        try? Data("# Perf \(marker)\n".utf8).write(to: small)
        var untitled: [URL] = []
        defer {
            for url in [small] + untitled {
                if Untitled.contains(url) { Untitled.letGo(url) }
                Documents.existing(for: url)?.editor.textView.window?.performClose(nil)
            }
            try? FileManager.default.removeItem(at: small)
            NibDefaults.store.removeObject(forKey: "selection:" + small.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == small.path }) { ClosedItems.shared.forget(item) }
            RecentFiles.shared.remove(small)
        }
        AppDelegate.openFile(small)
        _ = await waitFor(20) { Documents.existing(for: small)?.ready == true && Documents.existing(for: small)?.held == true }
        if let file = Documents.existing(for: small) {
            let view = file.editor.textView
            var coordinated: [Double] = [], plain: [Double] = []
            for n in 1...5 {
                // Only once iCloud has this version: with one it hasn't confirmed, Nib keeps both
                // versions between markers rather than replace it (and so it should), which is
                // another measure (the first run wrote every 1.2 s and met that three times in five).
                await waitSynced(file, 20)
                let text = "# Perf \(marker)\nversion \(n) from another app\n"
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: small, options: [], error: &error) { url in
                    try? Data(text.utf8).write(to: url)   // in place, as a careful app writes
                }
                if let seen = await timed(5, { view.string == text }) { coordinated.append(seen) }
                try? await Task.sleep(for: .milliseconds(1_200))
            }
            for n in 1...3 {
                await waitSynced(file, 20)
                let line = "appended \(n) by a shell"
                let written = Date()
                append(line, to: small)
                if await timed(5, { view.string.contains(line) }) != nil { plain.append(Date().timeIntervalSince(written)) }
                try? await Task.sleep(for: .milliseconds(1_200))
            }
            if coordinated.isEmpty { missing.append("disk to screen (coordinated)") } else {
                let p = percentiles(coordinated)
                measured("a new version on disk to the screen, another app's coordinated write", "p50 \(ms(p.p50)), max \(ms(p.max)) (\(coordinated.count))", target: "≤ 200 ms", met: p.max <= 0.2)
            }
            if plain.isEmpty { missing.append("disk to screen (uncoordinated)") } else {
                let p = percentiles(plain)
                measured("a new version on disk to the screen, an uncoordinated write (echo >>)", "p50 \(ms(p.p50)), max \(ms(p.max)) (\(plain.count))", target: "≤ 200 ms", met: p.max <= 0.2)
            }
            // Keystrokes, main thread, a small file.
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            var keys: [Double] = []
            for character in "typing for the measure \(marker), a line of it\n" {
                let start = Date()
                view.insertText(String(character), replacementRange: view.selectedRange())
                keys.append(Date().timeIntervalSince(start))
                try? await Task.sleep(for: .milliseconds(30))
            }
            let k = percentiles(keys)
            let p99 = keys.sorted()[min(keys.count - 1, Int(Double(keys.count) * 0.99))]
            measured("a keystroke on the main thread, small file (Rune's share; glass to glass needs Typometer)",
                     "p50 \(ms(k.p50)), p99 \(ms(p99)), max \(ms(k.max))", target: "≤ 8.3 ms, p99 ≤ 16 ms", met: p99 <= 0.016)
            await file.flush(reason: "test")
        } else {
            missing.append("the small test file")
        }

        // Big files, as untitled buffers: 5 MB of JavaScript, 2.4 MB of Markdown.
        func big(_ name: String, _ text: String, keyword: String, plainWord: String) async -> (shown: Double, colored: Double?, document: Document)? {
            guard let url = Untitled.create(text: text, name: name) else { return nil }
            untitled.append(url)
            let started = Date()
            AppDelegate.openFile(url)
            guard let shown = await timed(15, {
                guard let open = Documents.existing(for: url), open.ready, open.editor.textView.window?.isVisible == true else { return false }
                return (open.editor.textView.string as NSString).length == (text as NSString).length
            }), let open = Documents.existing(for: url) else { return nil }
            let view = open.editor.textView
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scroll(.zero)
            let at = (view.string as NSString).range(of: keyword).location, plainAt = (view.string as NSString).range(of: plainWord).location
            let colored = await timed(15) { drawnColor(view, at: at) != "none" && drawnColor(view, at: at) != drawnColor(view, at: plainAt) }
            return (shown, colored.map { _ in Date().timeIntervalSince(started) }, open)
        }
        // Just under 5 MB: ED9 highlights files up to 5,000,000 characters, and none larger (the
        // first measure made 5,000,014 and waited in vain for colors).
        var js = "", n = 0
        while js.utf8.count < 4_950_000 {
            n += 1
            js += "// block \(n)\nfunction handler\(n)(event) {\n  const value = event.detail?.value ?? \(n);\n  return value > 10 ? \"big\" : `small ${value}`;\n}\n"
        }
        if let result = await big("perf-\(marker).js", js, keyword: "function", plainWord: "event)") {
            measured("open a 5 MB JavaScript file (untitled, on this Mac), first shown", ms(result.shown), target: "first paint ≤ 300 ms", met: result.shown <= 0.3)
            measured("open a 5 MB JavaScript file, colored at the top", result.colored.map(ms) ?? "not within 15 s", target: "fully highlighted ≤ 1 s", met: result.colored.map { $0 <= 1 } ?? false)
            result.document.editor.textView.window?.performClose(nil)
        } else {
            missing.append("5 MB JavaScript")
        }
        var md = "# Scratch-sized \(marker)\n", m = 0
        while md.utf8.count < 2_400_000 {
            m += 1
            md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
        }
        if let result = await big("perf-\(marker).md", md, keyword: "# Scratch", plainWord: "Line 1:") {
            measured("open the scratch file at 2.4 MB, \(m) lines (untitled), first shown", ms(result.shown), target: "opens ≤ 300 ms", met: result.shown <= 0.3)
            // (A reload at this size is measured in `bigfile`: an untitled buffer is Nib's own
            // file, watched by nobody, and a 2.4 MB file in iCloud Drive slows iCloud for minutes.)
            result.document.editor.textView.window?.performClose(nil)
            // A three-way merge at that size: an edit near the top on one side, near the end on the other.
            // "Line 31:" (30 is an item line: "Line 30:" isn't there, and inserting at "not found"
            // threw an Objective-C exception through Swift code, which crashed Nib later, twice).
            let base = md, near = (md as NSString).range(of: "Line 31:").location
            guard near != NSNotFound else { log.check(false, "the merge's text has line 31"); return }
            let ours = (md as NSString).replacingCharacters(in: NSRange(location: near, length: 0), with: "ours \(marker)\n")
            let theirs = md + "theirs \(marker)\n"
            let merged = await Task.detached { () -> Double in
                let start = Date()
                _ = Merge.threeWay(base: base, .init(text: ours, label: "Air · 10:00"), .init(text: theirs, label: "Mini · 10:00"))
                return Date().timeIntervalSince(start)
            }.value
            measured("a three-way merge at 2.4 MB (off the main thread)", ms(merged), target: "≤ 100 ms", met: merged <= 0.1)
        } else {
            missing.append("2.4 MB Markdown")
        }
        log.check(missing.isEmpty, "every measure taken\(missing.isEmpty ? "" : " but: " + missing.joined(separator: ", "))")
    }

    /// Where opening a big file goes (§6.5: 5 MB of JavaScript shown ≤ 300 ms, 2.4 MB of Markdown
    /// too): each as an untitled buffer, from asking to its window up with the text, and the open's
    /// steps, then colored at the top.
    static func bigOpen(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        var js = "", n = 0
        while js.utf8.count < 4_950_000 {
            n += 1
            js += "// block \(n)\nfunction handler\(n)(event) {\n  const value = event.detail?.value ?? \(n);\n  return value > 10 ? \"big\" : `small ${value}`;\n}\n"
        }
        var md = "# Scratch-sized \(marker)\n", m = 0
        while md.utf8.count < 2_400_000 {
            m += 1
            md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
        }
        for (name, text, keyword) in [("bigopen-\(marker).js", js, "function"), ("bigopen-\(marker).md", md, "# Scratch")] {
            guard let url = Untitled.create(text: text, name: name) else { continue }
            defer { Untitled.letGo(url) }
            let asked = Date()
            AppDelegate.openFile(url)
            _ = await waitFor(20) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
            let shown = Date().timeIntervalSince(asked)
            guard let document = Documents.existing(for: url) else { log.line("\(name): didn't open"); continue }
            let view = document.editor.textView, at = (view.string as NSString).range(of: keyword).location
            let plain = drawnColor(view, at: at)
            _ = await waitFor(15) { drawnColor(view, at: at) != "none" && drawnColor(view, at: at) != plain || drawnColor(view, at: at) != "none" }
            let colored = Date().timeIntervalSince(asked)
            log.line("\(name) · \(text.utf8.count / 1000) KB · shown \(Int(shown * 1000)) ms · colored \(Int(colored * 1000)) ms · \(document.openSteps.joined(separator: " · "))")
            view.window?.performClose(nil)
            _ = await waitFor(10) { Documents.existing(for: url) == nil }
        }
    }

    /// When this process started (§6.5's cold launch is measured from it).
    static func processStart() -> Date? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
    }

    /// This process's physical footprint, as Activity Monitor's Memory column, in MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// CPU seconds so far, and wakeups (idle and interrupt) so far.
    static func usage() -> (cpu: Double, wakeups: UInt64) {
        var times = rusage()
        getrusage(RUSAGE_SELF, &times)
        let cpu = Double(times.ru_utime.tv_sec + times.ru_stime.tv_sec) + Double(times.ru_utime.tv_usec + times.ru_stime.tv_usec) / 1_000_000
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return (cpu, ok == 0 ? info.ri_pkg_idle_wkups + info.ri_interrupt_wkups : 0)
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

    /// How long until `condition` holds (nil: not within `seconds`), polled every millisecond, the
    /// main run loop turning meanwhile: for what's measured against a target (`waitFor` looks every 50 ms).
    static func timed(_ seconds: Double, _ condition: () -> Bool) async -> Double? {
        let start = Date(), deadline = start.addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return Date().timeIntervalSince(start) }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition() ? Date().timeIntervalSince(start) : nil
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

/// The main thread's longest wait, sampled every 20 ms while it runs.
@MainActor
final class StallWatch {
    private(set) var longest = 0.0
    /// When the longest wait ended.
    private(set) var longestEnded: Date?
    private var last = Date()
    private var timer: Timer?

    func start() {
        last = Date()
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                if now.timeIntervalSince(self.last) > self.longest { self.longest = now.timeIntervalSince(self.last); self.longestEnded = now }
                self.last = now
            }
        }
        // In every mode: a sheet coming up runs the run loop in another, and a timer in the
        // default mode alone took that for the main thread being held (`headings`, 2026-10-02).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// A scenario's Nib watching its own main thread from another: when it hasn't answered for
/// 10 s, `sample` records where it waits, beside the scenario's log, and a STALL line says so
/// once it answers. `merge` sat silent for 100 s in the suite of 2026-10-02 and was killed, and
/// the runner's sample of it went with the next run.
enum MainThreadWatch {
    static func start(_ log: HarnessLog) {
        let log = log, pid = ProcessInfo.processInfo.processIdentifier
        let base = URL(fileURLWithPath: log.path).deletingPathExtension()
        Thread.detachNewThread {
            var stalls = 0
            while true {
                Thread.sleep(forTimeInterval: 1)
                let answered = DispatchSemaphore(value: 0), asked = Date()
                DispatchQueue.main.async { answered.signal() }
                guard answered.wait(timeout: .now() + 10) == .timedOut else { continue }
                stalls += 1
                let file = base.path + "-stall-\(stalls).txt"
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = ["\(pid)", "3", "-file", file]
                sample.standardOutput = FileHandle.nullDevice
                sample.standardError = FileHandle.nullDevice
                try? sample.run()
                sample.waitUntilExit()
                answered.wait()
                log.line("STALL the main thread didn't answer for \(Int(Date().timeIntervalSince(asked))) s: sampled in \((file as NSString).lastPathComponent)")
            }
        }
    }
}

/// A scenario's Nib saves no window's place in the Mac's defaults, which are the bundle's, the
/// Nib in daily use's too. SwiftUI names a window's frame (its autosave name) as it makes the
/// window, before Nib sees it, and a cascaded file window saved its place under that name (the
/// suite, 2026-10-01). The names stay, so a window opens at the size the user's has (without
/// them the merge view opened too small to resolve its blocks); only the saving goes.
enum ScenarioWindows {
    static func keepFramesOut() {
        guard let save = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.saveFrame(usingName:))),
              let skip = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.nibScenarioSaveFrame(usingName:))) else { return }
        method_exchangeImplementations(save, skip)
    }
}

extension NSWindow {
    /// In place of saveFrame(usingName:), in a scenario's Nib only.
    @objc fileprivate func nibScenarioSaveFrame(usingName name: NSWindow.FrameAutosaveName) {}
}

/// A scenario's Nib gives the Mac's focus back to the app that had it, at launch and whenever it
/// comes forward (PRD §8: keystrokes typed meanwhile landed in the test windows), unless the
/// scenario takes it: find, palette and snapshot need a key window, for a few seconds.
@MainActor
enum ScenarioFocus {
    private static var noNap: NSObjectProtocol?
    private static var wanted = false
    private static var other: NSRunningApplication?

    /// Before Nib has come forward, while the app in front is still the one to give it back to.
    static func start() {
        guard NibDefaults.store.string(forKey: "NibScenario") != nil else { return }
        // Never napped. Out of sight (the screen locked, or windows over it), macOS slows an
        // app's timers after half a minute: a scenario's 30 ms keystrokes and 50 ms waits took
        // five times as long (`nap`, 2026-10-02), and the suite runs out of sight.
        if !NibDefaults.store.bool(forKey: "NibAllowNap") {   // -NibAllowNap YES: as before, for `nap` to show the difference
            noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                          reason: "Rune's scenario tests keep their own time")
        }
        let front = NSWorkspace.shared.frontmostApplication
        other = front == .current ? nil : front
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != .current { other = app } else { giveBack() }
            }
        }
    }

    /// The name of the app that keeps the focus, for the log.
    static var keeper: String { other?.localizedName ?? "none" }

    static func take() {
        wanted = true
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Done with it: back to the app that had it.
    static func giveBackNow() {
        wanted = false
        giveBack()
    }

    private static func giveBack() {
        guard !wanted, let other, !other.isTerminated else { return }
        NSApp.yieldActivation(to: other)
        other.activate(from: .current, options: [])
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

extension NSRange {
    /// nil for NSNotFound, as `range(of:)` says "not there".
    var nilIfMissing: NSRange? { location == NSNotFound ? nil : self }
}
#endif
