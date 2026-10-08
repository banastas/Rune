// Find and replace (PRD ED7, KB1): one per editor. The query, the options (regular
// expression, match case, whole word, in the selection), every match (found off the main
// thread, and again as the text changes), the one selected, and Replace and Replace All
// (one undo step). Typing in the field goes to the first match from where the caret was,
// as Sublime does. ⌘E puts the selection in the system's find clipboard, which ⌘F and ⌘G
// read, as in every Mac app. With no matches, Find in History (SY18) looks for it in the file's
// History and says which version has it.

import AppKit
import NibSync
import NibText

@MainActor
@Observable
final class FindSession {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Typing starts from the caret; once on a match, from that match, so it stays put
            // while it still matches.
            if current == nil, let view = editor?.textView { anchor = view.selectedRange().location }
            search(moving: true)
        }
    }
    var replacement = ""
    var options = SearchOptions() { didSet { if options != oldValue { search(moving: true) } } }
    /// Only within what was selected when this was turned on.
    var inSelection = false {
        didSet {
            guard inSelection != oldValue else { return }
            scope = inSelection ? editor?.textView.selectedRange() : nil
            if scope?.length == 0 { scope = nil; inSelection = false; NSSound.beep() }
            search(moving: false)
        }
    }
    /// The Replace row (⌥⌘F, or the bar's disclosure button).
    var replacing = false
    private(set) var shown = false
    private(set) var matches: [NSRange] = []
    private(set) var current: Int?
    private(set) var failure: String?
    private(set) var scope: NSRange?
    /// Bumped to ask the bar to put the caret in its find field (⌘F while it's open).
    private(set) var focusRequests = 0

    /// Find in History (SY18): with no matches in the text, what the file's History has.
    enum InHistory: Equatable {
        case none, looking
        /// The newest version with a match, and how many it has.
        case found(HistoryEntry, count: Int)
        /// In no version History keeps.
        case nowhere
    }
    private(set) var inHistory: InHistory = .none
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    /// A search of 3 characters or more; the bar still that long first.
    static let historyMinimum = 3
    static let historyPause: Duration = .milliseconds(400)

    @ObservationIgnored weak var editor: Editor?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var version = 0
    /// Where the caret was when the query last changed: typing finds from here.
    @ObservationIgnored private var anchor = 0
    @ObservationIgnored private var saidEmpty = false

    /// "3 OF 12", "12 MATCHES", "NO MATCHES", or what's wrong with the pattern.
    var countLabel: String {
        if let failure { return failure }
        if query.isEmpty { return "" }
        if matches.isEmpty {
            if inSelection { return "NONE IN THE SELECTION" }   // short enough for its slot (F81)
            switch inHistory {
            case .none: return "NO MATCHES"
            case .looking: return "NO MATCHES · LOOKING IN HISTORY…"
            case .found(let entry, _): return "NO MATCHES · IN HISTORY: \(Self.historyStamp(entry.time)) ›"
            case .nowhere: return "NO MATCHES · NOT IN HISTORY EITHER"
            }
        }
        let total = matches.count >= TextSearch.limit ? "\(TextSearch.limit.formatted())+" : matches.count.formatted()
        if let current { return "\((current + 1).formatted()) OF \(total)" }
        return "\(total) MATCH\(matches.count == 1 ? "" : "ES")"
    }

    // MARK: Opening and closing

    /// ⌘F, ⌥⌘F: the bar, its field holding the selection (if it's on one line) or else what
    /// it held last, or the find clipboard.
    func open(replace: Bool) {
        if let selected = selectedText(), !selected.contains("\n") { query = selected }
        else if query.isEmpty { query = Self.findClipboard ?? "" }
        if replace { replacing = true }
        anchor = editor?.textView.selectedRange().location ?? 0
        shown = true
        focusRequests += 1
        search(moving: false, now: true)
    }

    /// Escape, or the bar's Done: the matches no longer drawn, the caret back in the text.
    func close() {
        guard shown else { return }
        shown = false
        searchTask?.cancel()
        searchTask = nil
        historyTask?.cancel()
        historyTask = nil
        inHistory = .none
        matches = []
        current = nil
        editor?.findMatches = []
        editor?.textView.currentMatch = nil
        guard let view = editor?.textView else { return }
        view.window?.makeFirstResponder(view)
        // The text gets the bar's height back, laid out again, and the caret on the match can
        // drift out of view (`findjump`): into view again once it has. Not if anything moved
        // meanwhile: typing, Find All's carets, a scroll elsewhere (`carets`, 2026-10-06: it took
        // the view back from the end of the file to the first of 2,000 carets).
        let selection = view.selectedRange(), origin = view.visibleRect.origin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
            guard let view, view.window != nil, view.selectedRange() == selection, view.carets == nil,
                  abs(view.visibleRect.minY - origin.y) < 100 else { return }
            view.reveal(selection.location)
        }
    }

    // MARK: Moving between matches

    /// ⌘G, ⇧⌘G, and Return or ⇧Return in the field: the next match from the selection,
    /// round the end.
    func next(backwards: Bool = false) {
        // With the bar closed, ⌘G finds what the find clipboard holds (another app's ⌘E).
        if !shown || query.isEmpty, let saved = Self.findClipboard, !saved.isEmpty { query = saved }
        guard !query.isEmpty, let view = editor?.textView else { NSSound.beep(); return }
        if !shown || searchTask != nil { searchNow() }
        if Self.findClipboard != query { Self.findClipboard = query }
        let selection = view.selectedRange()
        let from = backwards ? selection.location : NSMaxRange(selection)
        guard let index = TextSearch.next(after: from, in: matches, backwards: backwards) else {
            NSSound.beep()
            editor?.document?.show(failure ?? "NO MATCHES FOR “\(query)”", for: 4)
            return
        }
        select(index)
        anchor = matches[index].location
    }

    private func select(_ index: Int) {
        guard let view = editor?.textView, matches.indices.contains(index) else { return }
        current = index
        view.setSelectedRange(matches[index])
        view.currentMatch = matches[index]
        view.reveal(matches[index].location)   // not the find indicator, which scrolls as AppKit does (Reveal.swift)
        // Said, as the focus stays in the field: VoiceOver heard nothing of a jump (the QA review's F38).
        if shown {
            let text = view.string as NSString
            let line = text.substring(with: text.lineRange(for: matches[index])).trimmingCharacters(in: .whitespacesAndNewlines)
            Announce.sentence("\(index + 1) of \(matches.count): \(line.count > 80 ? String(line.prefix(80)) + "…" : line)")
        }
    }

    /// The caret moved: which match, if any, is the selected one.
    func selectionChanged() {
        guard let view = editor?.textView else { return }
        current = matches.firstIndex(of: view.selectedRange())
        view.currentMatch = shown ? current.map { matches[$0] } : nil
    }

    /// ⌘E: the selection as the query, here and in the system's find clipboard.
    func useSelection() {
        guard let selected = selectedText(), !selected.isEmpty else { NSSound.beep(); return }
        Self.findClipboard = selected
        anchor = editor?.textView.selectedRange().location ?? anchor
        query = selected
    }

    /// Find All (⌥Return, as in Sublime): every match selected, a caret each (ED8), and the bar
    /// closed, for typing at all of them.
    func findAll() {
        guard let view = editor?.textView, failure == nil, !query.isEmpty else { NSSound.beep(); return }
        searchNow()
        guard !matches.isEmpty else {
            NSSound.beep()
            editor?.document?.show(failure ?? "NO MATCHES FOR “\(query)”", for: 4)
            return
        }
        let found = matches, primary = TextSearch.next(after: view.selectedRange().location, in: found) ?? 0
        if Self.findClipboard != query { Self.findClipboard = query }
        close()
        view.wholeWordSearch = options.wholeWord
        view.setCarets(Carets(found.map(Caret.init(range:)), primary: primary))
        let count = found.count >= TextSearch.limit ? "\(TextSearch.limit.formatted()) (THE MOST AT ONCE)" : found.count.formatted()
        editor?.document?.show("\(count) SELECTED", for: 4)
    }

    // MARK: Replacing

    /// Replace (⌥⌘E, Return in the Replace field): the selected match, then on to the next.
    /// With no match selected, it goes to the next one first.
    func replaceCurrent() {
        // Only with the Replace row shown: from a find-only bar, its key replaced with what nobody
        // could see, "" most often (the QA review's F1, 2026-10-07).
        guard replacing, let view = editor?.textView, failure == nil, !query.isEmpty else { NSSound.beep(); return }
        if searchTask != nil { searchNow() }
        let selection = view.selectedRange()
        guard matches.contains(selection) else { next(); return }
        guard let with = try? TextSearch.replacement(for: selection, in: view.string, query: query, template: replacement, options: options) else { NSSound.beep(); return }
        view.breakUndoCoalescing()   // its own undo step, not part of the typing before it
        guard view.shouldChangeText(in: selection, replacementString: with) else { return }
        view.textStorage?.replaceCharacters(in: selection, with: with)
        view.didChangeText()
        view.undoManager?.setActionName("Replace")
        let after = selection.location + (with as NSString).length
        view.setSelectedRange(NSRange(location: after, length: 0))
        searchNow()
        if let index = TextSearch.next(after: after, in: matches) { select(index) }
    }

    /// Replace All (⌃⌥Return): every match (in the selection, if that's on), one undo step,
    /// and the strip says how many.
    func replaceAll() {
        guard replacing, let view = editor?.textView, failure == nil, !query.isEmpty else { NSSound.beep(); return }   // as Replace (F1)
        let text = view.string
        guard let found = try? TextSearch.matches(of: query, in: text, options: options, within: scope),
              let first = found.first, let last = found.last,
              let result = try? TextSearch.replaceAll(query, with: replacement, in: text, options: options, within: scope) else {
            NSSound.beep()
            editor?.document?.show("NOTHING REPLACED · NO MATCHES FOR “\(query)”", for: 6)
            return
        }
        // Only the stretch from the first match to the end of the last changes.
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let delta = (result.text as NSString).length - (text as NSString).length
        let with = (result.text as NSString).substring(with: NSRange(location: span.location, length: span.length + delta))
        view.breakUndoCoalescing()
        guard view.shouldChangeText(in: span, replacementString: with) else { return }
        view.textStorage?.replaceCharacters(in: span, with: with)
        view.didChangeText()
        view.undoManager?.setActionName("Replace All")
        view.setSelectedRange(NSRange(location: span.location, length: 0))
        let count = result.count >= TextSearch.limit ? "\(TextSearch.limit.formatted()) (THE MOST AT ONCE)" : result.count.formatted()
        editor?.document?.show("REPLACED \(count) MATCH\(result.count == 1 ? "" : "ES") · ⌘Z UNDOES", for: 8)   // as every other line says it (F67)
        searchNow()
    }

    // MARK: Searching

    /// Before an edit: the in-selection range grows, shrinks or moves with it.
    func textWillChange(in range: NSRange, change: Int) {
        guard var scope else { return }
        if range.location >= NSMaxRange(scope) { return }
        if NSMaxRange(range) <= scope.location { scope.location += change }
        else { scope.length = max(0, scope.length + change) }
        self.scope = scope
    }

    /// The text changed while the bar is open: the matches again, a moment later.
    func textChanged() {
        guard shown else { return }
        search(moving: false)
    }

    /// Off the main thread, 120 ms after the last change (at once when the bar opens). With
    /// `moving`, the query or an option changed: the first match from the anchor is selected.
    private func search(moving: Bool, now: Bool = false) {
        guard shown, let text = editor?.textView.string else { return }
        version += 1
        let version = self.version
        searchTask?.cancel()
        let query = self.query, options = self.options, scope = self.scope
        searchTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { Self.run(query, text, options, scope) }.value
            guard let self, !Task.isCancelled, version == self.version else { return }
            self.searchTask = nil
            self.apply(result)
            if moving, let index = TextSearch.next(after: self.anchor, in: self.matches) { self.select(index) }
        }
    }

    /// At once, on the main thread (before Replace, and ⌘G while a search is on its way).
    private func searchNow() {
        searchTask?.cancel()
        searchTask = nil
        version += 1
        guard let text = editor?.textView.string else { return }
        apply(Self.run(query, text, options, scope))
    }

    nonisolated private static func run(_ query: String, _ text: String, _ options: SearchOptions, _ scope: NSRange?) -> Result<[NSRange], TextSearch.Failure> {
        do { return .success(try TextSearch.matches(of: query, in: text, options: options, within: scope)) }
        catch let failure as TextSearch.Failure { return .failure(failure) }
        catch { return .success([]) }
    }

    private func apply(_ result: Result<[NSRange], TextSearch.Failure>) {
        switch result {
        case .success(let found): failure = nil; matches = found
        case .failure(let why): failure = why.description; matches = []
        }
        // "No matches", or what's wrong with the pattern, said once as it comes (F38).
        if shown, !query.isEmpty, matches.isEmpty {
            if !saidEmpty { Announce.hud(countLabel); saidEmpty = true }
        } else {
            saidEmpty = false
        }
        selectionChanged()
        editor?.findMatches = shown ? matches : []
        lookInHistory()
    }

    // MARK: Find in History (SY18)

    /// No matches in the text for 3 or more characters (not in the selection): the file's
    /// History, newest version first, with the bar's options, once the bar's been still 0.4 s.
    /// A change to the search or the text starts over (`version`).
    private func lookInHistory() {
        historyTask?.cancel()
        historyTask = nil
        guard shown, failure == nil, matches.isEmpty, !inSelection, query.count >= Self.historyMinimum,
              let document = editor?.document, !document.historyEntries.isEmpty else {
            inHistory = .none
            return
        }
        inHistory = .none
        let query = self.query, options = self.options, version = self.version
        let entries = document.historyEntries, history = document.history
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.historyPause)
            guard !Task.isCancelled, let self, version == self.version else { return }
            self.inHistory = .looking
            let search = Task.detached(priority: .utility) {
                HistorySearch.newest(query, options: options, in: entries,
                                     load: { history.unverifiedData($0).map { TextFile.decode($0).text } },
                                     isCancelled: { Task.isCancelled })
            }
            let outcome = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
            guard !Task.isCancelled, version == self.version, self.shown else { return }
            self.historyTask = nil
            switch outcome {
            case .found(let entry, let found): self.inHistory = .found(entry, count: found.count)
            case .nowhere: self.inHistory = .nowhere
            case .badPattern, .cancelled: self.inHistory = .none; return
            }
            Announce.sentence(self.historySaid)
        }
    }

    /// What's said to VoiceOver as History answers.
    var historySaid: String {
        switch inHistory {
        case .found(let entry, let count):
            "No matches in the text. \(count == 1 ? "One match" : "\(count) matches") in History, in the version from \(HistoryView.when(entry.time)). Click to see it."
        case .nowhere: "No matches in the text, or in its History."
        default: Spoken.sentence(countLabel)
        }
    }

    /// The found version, for the History window to open on (SY18): the version, and the search
    /// to show in it.
    func historyFocus() -> HistoryFocus? {
        guard case .found(let entry, _) = inHistory else { return nil }
        return HistoryFocus(sha256: entry.sha256, time: entry.time, query: query, options: options)
    }

    /// Opens a History window (the bar's, which has SwiftUI's `openWindow`).
    @ObservationIgnored var openHistoryWindow: ((URL) -> Void)?

    /// The bar's found line, clicked: the History window, on that version, the search shown.
    func showInHistory() {
        guard let focus = historyFocus(), let document = editor?.document else { NSSound.beep(); return }
        document.historyFocus = focus
        openHistoryWindow?(document.url)
    }

    /// A version's time as the bar's slot has room for: "14:02" today, "YESTERDAY 14:02",
    /// "TUE 14:02" this week, "SEP 26 14:02" before (24-hour, as every time in Rune: F64).
    static func historyStamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = date.formatted(Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "YESTERDAY \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        let english = Locale(identifier: "en_US")
        if days < 7 { return date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(english)).uppercased() + " " + time }
        return date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(english)).uppercased() + " " + time
    }

    private func selectedText() -> String? {
        guard let view = editor?.textView else { return nil }
        let range = view.selectedRange()
        return range.length > 0 ? (view.string as NSString).substring(with: range) : nil
    }

    /// The system's find clipboard, shared by every app's ⌘E and ⌘G.
    static var findClipboard: String? {
        get { NSPasteboard(name: .find).string(forType: .string) }
        set {
            let board = NSPasteboard(name: .find)
            board.clearContents()
            if let newValue { board.setString(newValue, forType: .string) }
        }
    }
}
