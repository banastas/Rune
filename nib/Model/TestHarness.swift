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
    /// -NibFailPauses n -NibFailPausesFor <name prefix>: the first n holds of those files fail
    /// as they do when iCloud's helper doesn't answer (the `holdretry` scenario).
    static var failPauses = UserDefaults.standard.integer(forKey: "NibFailPauses")
    static let failPausesFor = UserDefaults.standard.string(forKey: "NibFailPausesFor")
    /// The `refusal` scenario: the next uploads refused as if another Mac had uploaded first,
    /// and the next fetches answered "nothing newer", as iCloud can for a held file.
    static var refuseUploads = 0
    static var staleFetches = 0
    /// The next fetch brings this, as if another Mac had uploaded it (the `merge` scenario's
    /// -NibNoteTiming variants: versions from iCloud are the ones that wait for their note).
    static var fakeNewer: Data?
    /// -NibFailResumes n: the next hand-backs fail as when iCloud's helper doesn't answer;
    /// -NibUnsupportedPauses n (with -NibFailPausesFor): the next holds answer "not supported".
    static var failResumes = UserDefaults.standard.integer(forKey: "NibFailResumes")
    static var unsupportedPauses = UserDefaults.standard.integer(forKey: "NibUnsupportedPauses")

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
            case "crash-blocks": await crashWithBlocks(document, log, marker)
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
            case "files": await files(log, marker)
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
            case "handback": await handBack(document, log)
            case "handback-return": await handBackReturn(document, log)
            case "untitled-return": await untitledReturn(log, marker)
            case "untitled-quit": await untitledQuit(log, marker)
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
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
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
        await document.flush(reason: "test")
        log.check(fileText(document) == original, "and the file is as it was")
        view.window?.performClose(nil)
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
        log.check(menu == ["Indent", "Outdent", "Toggle Comment", "Duplicate Line", "Move Line Up", "Move Line Down", "Select Line", "Join Lines", "Go to Line…"],
                  "the Text menu: \(menu.joined(separator: ", "))")
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
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
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
        log.check(titles == ["Find…", "Find and Replace…", "Find Next", "Find Previous", "Use Selection for Find", "Replace", "Replace All"],
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
        NSApp.activate(ignoringOtherApps: true)
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
                  "⌘F \(front ? "from the menu" : "(the text view's action: macOS didn't let Nib come forward)"): the bar, the selection in its field, the caret there, \(find.countLabel)")
        let first = range("Deploy").location, redeploy = range("redeploy").location + 2
        log.check(drawnColor(view, at: first, .backgroundColor) == "#FFE792" && drawnColor(view, at: first) == "#000000"
                  && drawnColor(view, at: range("deploy").location, .backgroundColor) != "#FFE792",
                  "the other matches in the scheme's find color, black on #FFE792; the selected one as the selection")

        // ⌘G, ⇧⌘G, round the end.
        find.next()
        let third = view.selectedRange().location == redeploy && find.countLabel == "3 OF 4"
        find.next(); find.next()
        let wrapped = view.selectedRange().location == first && find.countLabel == "1 OF 4"
        find.next(backwards: true)
        log.check(third && wrapped && selected() == "DEPLOY" && find.countLabel == "4 OF 4", "⌘G, round the end to the top, and ⇧⌘G back round")

        // The options.
        find.options.matchCase = true
        let cased = await waitFor(3) { find.matches.count == 2 }
        find.options.wholeWord = true
        let whole = await waitFor(3) { find.matches.count == 1 }
        find.options = SearchOptions()
        let back = await settle("4 OF 4")
        log.check(cased && whole && back, "Match Case: 2 matches; and Whole Word: 1")

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

        // Replace, then Replace All, $1 kept; one undo step each.
        find.query = "v1\\.(\\d+)"
        _ = await settle("1 OF 2")
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
        log.check(inside && view.string == "Deploy to seedbox.\nship again; reship later.\nDEPLOY v1.2 and v1.10\n",
                  "In Selection: 2 matches there, and only they're replaced")
        view.undoManager?.undo(); await endOfEvent(view)
        find.inSelection = false

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
        defer {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
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
        NSApp.activate(ignoringOtherApps: true)
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
        let folder = await waitFor(5) { session.entries.contains { $0.group == "Nib Folder" } }
        await picture("files")
        let groups = session.entries.map(\.group).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        let ids = session.entries.map(\.id)
        log.check(groups.first == "Scratch" && groups.prefix(2).last == "Open" && Set(ids).count == ids.count && folder
                  && session.entries.first { $0.name == url.lastPathComponent }?.group == "Open",
                  "Go to File: \(groups.joined(separator: ", ")), each file once (\(ids.count)), this file under Open")
        let ranked = CommandPalette.results(for: "palette-", in: session.entries)
        let letters = CommandPalette.results(for: "pltt", in: session.entries).first?.name
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
            log.check(ran, "Sync Log, chosen: its window opens once the palette has gone (Nib not in front, so not a text command)")
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
        let atBlock = await waitFor(2) { document.caretBlock != nil }
        document.resolveBlock(.both)
        await endOfEvent(view)
        try? await Task.sleep(for: .milliseconds(600))
        let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
        let both = "- ours \(marker)\n- theirs \(marker)\n"
        let journaled = journal.read(path: document.url.path)?.text.contains(both) == true
        log.check(atBlock && ours(document, marker).isEmpty && journaled && fileText(document).contains("- ours \(marker)\n======="),
                  "Keep Both in the buffer and the journal; the file still has the block (saving held off)")
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
        // The other Mac's version, the base plus a line at the end. Its note comes first, as it
        // mostly does from iCloud; or (-NibNoteTiming after) 3 s after the version, as at 20:55; or
        // (never) not at all.
        let timing = UserDefaults.standard.string(forKey: "NibNoteTiming") ?? "before"
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
        if timing == "never" || timing == "late" {
            let whole = await waitFor(15) { !ours(document, marker).isEmpty }
            let line = events.read().dropFirst(before).last { $0.event == "conflict" }
            // Through the wait for its note, not a disk check taking it for another app's.
            log.check(whole && line?.detail?.contains("no version both had is known") == true && line?.detail?.hasPrefix("changed by another Mac") == true,
                      "no note in 10 s: both whole versions between markers, as before (\(line?.detail ?? "no conflict line"))")
            UserDefaults.standard.register(defaults: ["NibHoldUploads": false])
            if timing == "never" {
                let resolved = await keepBoth(document, marker)
                log.check(resolved, "and Keep Both resolves it")
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

    /// Files and tabs (ED2): a test file opens in its own window, as a tab beside another file's
    /// and never the scratch window's; opening it again brings the same window forward, one
    /// buffer per file; typing saves it; closing its tab hands it back to iCloud; and a file
    /// outside the test folders is refused before it's read (the M1 safety rule, §8).
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
        let tries = [a, b].map { url in SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read()
            .last { $0.path == url.path && $0.event == "pause" && ($0.detail == nil || $0.detail!.hasPrefix("held")) }?.detail ?? "held at once" }
        log.check(bothHeld, "both new files are held (\(tries.joined(separator: ", ")))")
        log.check(openB && window(a)?.tabGroup?.windows.contains { $0 === window(b) } == true
                  && window(a)?.tabGroup?.windows.contains { $0 === Documents.scratch.editor.textView.window } != true,
                  "a second file is a tab beside it (\(window(a)?.tabGroup?.windows.count ?? 0) tabs; b: \(window(b)?.tabGroup?.windows.count ?? 0) tabs, id \(window(b)?.tabbingIdentifier ?? "none"), visible \(window(b)?.isVisible ?? false)), the scratch window apart")
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
        }
        window(b)?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: b) == nil }
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
            UserDefaults.standard.removeObject(forKey: "syntax:" + url.path)
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
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
        log.check(items.contains("Automatic (Plain Text)") && items.contains("JavaScript") && items.contains("Shell"),
                  "View › Syntax has Automatic and the languages (\(items.joined(separator: ", ")))")
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
        log.check(again.syntaxName == "PLAIN TEXT" && plain && UserDefaults.standard.string(forKey: "syntax:" + url.path) == nil,
                  "Automatic goes back to what the file's name says (\(again.syntaxName))")
        again.pickSyntax(.language(.shell))
        log.check(again.editor.syntax?.root == "source.shell.bash", "Shell on a file that doesn't say zsh is Bash (\(again.editor.syntax?.root ?? "none"))")
        await close()
    }

    /// Theme import (HL2-HL4): a scheme file, then Import from Sublime Text from a generated
    /// Sublime folder (a .tmTheme with a Packages/User override, a font), then the original An
    /// Old Hope, which keeps the Nib edition. The editor redraws each time without an edit.
    /// Everything it changes (the scheme, the font, the report, the Themes folder) is put back.
    static func themes(_ log: HarnessLog, _ marker: String) async {
        await waitReady(Documents.scratch)
        let defaults = UserDefaults.standard
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
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
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
        log.check(schemes.currentID == before && drawn(at: heading) == "#E7CE57", "the heading in An Old Hope · Nib's yellow (\(drawn(at: heading)))")

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
        log.check(report.contains("IMPORTED SCENARIO PAPER") && report.contains("1 RULE · 5 GLOBALS USED · 1 NOT DRAWN YET (GUIDES)")
                  && report.contains("LIGHT BACKGROUND · NIB'S WINDOWS STAY DARK"), "and reported: \(report)")
        log.check(NSApp.effectiveAppearance.name == .darkAqua && view.window?.effectiveAppearance.name == .darkAqua, "Nib's windows stay dark")
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
            UserDefaults.standard.removeObject(forKey: "NibSublimeFolder")
            UserDefaults.standard.removeObject(forKey: "NibSublimePackages")
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
        log.check(schemes.currentID == Schemes.builtIn && back && (schemes.report ?? "").contains("KEPT AN OLD HOPE · NIB"),
                  "the original An Old Hope keeps the Nib edition (\(schemes.report ?? "no report"))")

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
        guard let one = await newBuffer() else { log.check(false, "⌘N opened an untitled buffer"); return }
        let name = one.url.lastPathComponent
        log.check(one.untitled && name.hasPrefix("Untitled") && one.editor.textView.window?.title == name,
                  "⌘N: a new untitled buffer, “\(name)”, in a window of its own")
        await type("untitled one \(marker)\n", into: one)
        let journaled = await waitFor(3) { journal.read(path: one.url.path)?.text.contains("untitled one \(marker)") == true }
        log.check(journaled, "its typing is in the journal within a moment")
        await one.flush(reason: "test")
        log.check(onDisk(one.url).contains("untitled one \(marker)") && one.state.line.hasPrefix("= ON THIS MAC ONLY"),
                  "and saved in Nib's own folder, on this Mac only (\(one.state.line))")
        let syncLog = (try? String(contentsOf: NibPaths.support.appendingPathComponent("sync.jsonl"), encoding: .utf8)) ?? ""
        log.check(!syncLog.contains(Untitled.folder.path), "nothing about it in the Sync Log: it never syncs")

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
        log.check(!FileManager.default.fileExists(atPath: threeURL.path) && !ClosedItems.shared.items.contains { $0.path == threeURL.path },
                  "an empty one just goes: nothing kept")

        guard let four = await newBuffer() else { log.check(false, "a fourth untitled buffer"); return }
        let fourURL = four.url
        await type("saved as a file \(marker)\n", into: four)
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nib-untitled-\(marker).txt")
        let refused = await Untitled.save(four, to: outside)
        log.check(!refused && !FileManager.default.fileExists(atPath: outside.path) && four.notice?.contains("NIB OPENS ONLY TEST FILES") == true,
                  "Save… outside the test folders: refused, nothing written (\(four.notice ?? "no notice"))")
        let target = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent("untitled-saved-\(marker).txt")
        defer { try? FileManager.default.removeItem(at: target) }
        let saved = await Untitled.save(four, to: target)
        let opened = await waitFor(10) { Documents.existing(for: target)?.ready == true && Documents.existing(for: fourURL) == nil }
        log.check(saved && opened && onDisk(target) == "saved as a file \(marker)\n" && !FileManager.default.fileExists(atPath: fourURL.path)
                  && !ClosedItems.shared.items.contains { $0.path == fourURL.path },
                  "Save…: the text in the file, the file open in its place, the untitled buffer gone")
        Documents.existing(for: target)?.editor.textView.window?.performClose(nil)
        _ = await waitFor(15) { Documents.existing(for: target) == nil }
        if let item = ClosedItems.shared.items.first(where: { $0.path == target.path }) { ClosedItems.shared.forget(item) }

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
        let held = await waitFor(20) { document.held }
        log.check(held, "held on a later try, \(Int(Date().timeIntervalSince(opened))) s after opening")
        let lines = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl")).read().filter { $0.path == url.path && $0.event == "pause" }
        let expected = 1 + UserDefaults.standard.integer(forKey: "NibFailPauses") + UserDefaults.standard.integer(forKey: "NibUnsupportedPauses")
        log.check(lines.first?.detail?.hasPrefix("not held yet") == true && lines.last?.detail == "held on try \(expected)",
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
        let events = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
        let before = events.read().count
        refuseUploads = 1
        staleFetches = 1
        await type("\n- typed before a refused upload \(marker)\n", into: document)
        let refreshed = await waitFor(30) { events.read().dropFirst(before).contains { $0.event == "refresh" } }
        let lines = events.read().dropFirst(before).filter { ["upload", "fetch", "refresh", "merge", "update"].contains($0.event) }
        log.check(refreshed && lines.contains { $0.detail?.hasPrefix("iCloud says there's nothing newer") == true },
                  "refused, and iCloud says nothing's newer: Nib refreshes anyway (\(lines.map { $0.word }.joined(separator: ", ")))")
        let kept = await waitFor(30) {
            fileText(document).contains("typed before a refused upload \(marker)") && isSynced(document)
                && document.editor.textView.string.contains("typed before a refused upload \(marker)")
        }
        log.check(kept, "the typing survives the refresh: in the buffer and the file, uploaded (\(document.state.line))")
        let after = events.read().dropFirst(before)
        log.check(!after.contains { $0.event == "conflict" } && !fileText(document).contains("<<<<<<< ") ,
                  "and the refresh brought back only what this Mac had uploaded: nothing between markers (\(after.map { $0.word }.joined(separator: ", ")))")
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
            UserDefaults.standard.removeObject(forKey: "selection:" + url.path)
            if let item = ClosedItems.shared.items.first(where: { $0.path == url.path }) { ClosedItems.shared.forget(item) }
        }
        let opened = Date()
        AppDelegate.openFile(url)
        _ = await waitFor(15) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window?.isVisible == true }
        guard let document = Documents.existing(for: url) else { log.check(false, "the file opened"); return }
        let view = document.editor.textView
        let yellow = "#E7CE57"
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let top = await waitFor(10) { drawnColor(view, at: 2) == yellow }
        log.check(top, "\(text.utf8.count / 1000) KB, \(n) lines: the heading at the top colored \(Int(Date().timeIntervalSince(opened) * 1000)) ms after asking to open it")
        let length = (view.string as NSString).length
        let last = (view.string as NSString).range(of: "## The last heading").location
        let scrolled = Date()
        view.scrollRangeToVisible(NSRange(location: length, length: 0))
        let bottom = await waitFor(5) { drawnColor(view, at: last + 3) == yellow }
        log.check(bottom, "scrolled to the end: the last heading colored \(Int(Date().timeIntervalSince(scrolled) * 1000)) ms later")
        view.setSelectedRange(NSRange(location: length, length: 0))
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
        _ = await waitFor(20) { Documents.existing(for: url) == nil }
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
        let shown = model.shown
        log.check(zip(shown, shown.dropFirst()).allSatisfy { $0.time >= $1.time }, "newest first")

        let start = Date().addingTimeInterval(-1)
        await type("\n- sync log \(marker)\n", into: document)
        let arrived = await waitFor(10) { model.rows.contains { $0.event.event == "save" && $0.event.path == document.url.path && $0.time >= start } }
        log.check(arrived && model.shown.first?.time ?? .distantPast >= start, "a save made while it's open appears, at the top")
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
        if let name = UserDefaults.standard.string(forKey: "NibSnapshotFile") {   // a file window, highlighted
            let url = ScratchLocation.url.deletingLastPathComponent().appendingPathComponent(name)
            AppDelegate.openFile(url)
            _ = await waitFor(10) { Documents.existing(for: url)?.ready == true && Documents.existing(for: url)?.editor.textView.window != nil }
            guard let file = Documents.existing(for: url), let window = file.editor.textView.window else { log.line("FAIL \(name) didn't open"); return }
            window.setFrame(NSRect(x: 80, y: 120, width: 820, height: 640), display: true)
            let end = UserDefaults.standard.bool(forKey: "NibSnapshotEnd") ? (file.editor.textView.string as NSString).length : 0
            file.editor.textView.setSelectedRange(NSRange(location: end, length: 0))
            file.editor.textView.scrollRangeToVisible(NSRange(location: end, length: 0))
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
