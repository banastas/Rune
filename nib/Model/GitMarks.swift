// Changes since the last commit (PRD ED12), for one document: the committed version from git
// (NibSync's `GitRepo`, off the main thread), the lines that differ from it (NibText's
// `LineChanges`, a moment after the text stops changing, against the copy in memory: no git call
// per keystroke), the gutter's and minimap's marks, and a line for the sync HUD. It looks again
// when Rune comes forward and when the repository's HEAD moves (a commit, a checkout: git appends
// to `logs/HEAD`, watched). Nothing for a file outside a repository, an untitled buffer, or a file
// over 5 MB (ED9's limit, where highlighting stops too).

import AppKit
import NibSync
import NibText
import Observation

@MainActor
@Observable
final class GitMarks {
    enum Status: Equatable {
        case none
        case untracked(branch: String?)
        case tracked(branch: String?)
    }

    private(set) var status: Status = .none
    private(set) var changes = LineChanges()

    @ObservationIgnored private weak var document: Document?
    @ObservationIgnored private var base: GitRepo.Base?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var recompute: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(document: Document) {
        self.document = document
    }

    /// The HUD's FILE panel line: "GIT · MAIN · 2 CHANGED · 1 ADDED", or nil outside a repository.
    var hudLine: String? {
        switch status {
        case .none: nil
        case .untracked(let branch): ["GIT", branch?.uppercased(), "NOT TRACKED YET"].compactMap { $0 }.joined(separator: " · ")
        case .tracked(let branch): ["GIT", branch?.uppercased(), changes.summary].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// As the file opens, and again whenever HEAD may have moved.
    func load() {
        guard let document, !document.untitled, !document.closing else { return clear() }
        let url = document.url
        loading?.cancel()
        loading = Task { [weak self] in
            let answer = await Task.detached(priority: .utility) { GitRepo.committed(url) }.value
            guard let self, !Task.isCancelled else { return }
            switch answer {
            case .none:
                self.clear()
            case .untracked(let branch):
                self.base = nil
                self.status = .untracked(branch: branch)
                self.show(LineChanges())
                self.watch(url)
            case .base(let base):
                self.base = base
                self.status = .tracked(branch: base.branch)
                self.watch(url)
                self.recomputeNow()
            }
        }
    }

    /// The text changed (typing, a merge, another app's version): the marks a moment after.
    func textChanged() {
        guard base != nil else { return }
        recompute?.cancel()
        recompute = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.recomputeNow()
        }
    }

    /// Rune came forward: a commit made meanwhile moved HEAD.
    func becameActive() {
        guard let document, status != .none || GitRepo.dotGit(above: document.url) != nil else { return }
        let url = document.url, known = base?.head
        Task { [weak self] in
            let head = await Task.detached(priority: .utility) { GitRepo.head(of: url) }.value
            if head != known { self?.load() }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        loading?.cancel()
        recompute?.cancel()
    }

    private func clear() {
        stop()
        base = nil
        status = .none
        show(LineChanges())
    }

    private func recomputeNow() {
        guard let document, let base else { return }
        guard !document.highlightingOff else { return show(LineChanges()) }   // over 5 MB (ED9)
        let text = document.editor.textView.string, committed = base.text
        recompute = Task { [weak self] in
            let changes = await Task.detached(priority: .utility) { LineChanges.between(committed: committed, text: text) }.value
            guard let self, !Task.isCancelled else { return }
            self.show(changes)
        }
    }

    private func show(_ new: LineChanges) {
        guard new != changes else { return }
        changes = new
        document?.editor.gitChanges = new
    }

    // MARK: Seeing and reverting a change (ED12, as Sublime Text's diff popup and Revert Hunk)

    /// The changes against the text as it is now, shown too: the marks lag typing by 0.3 s, and
    /// a revert must use the lines as they are. Nil outside a repository or over 5 MB.
    func changesNow() -> LineChanges? {
        guard let document, let base, !document.highlightingOff else { return nil }
        recompute?.cancel()
        let fresh = LineChanges.between(committed: base.text, text: document.editor.textView.string)
        show(fresh)
        return fresh
    }

    /// The line (from 0) the caret is on.
    private var caretLine: Int? {
        guard let editor = document?.editor else { return nil }
        return editor.lineIndex.line(at: editor.textView.selectedRange().location) - 1
    }

    /// Puts a change's committed lines back: an edit like typing, one ⌘Z step. False when it
    /// wasn't made (the lines moved on since: no longer a change as shown).
    @discardableResult
    func revert(_ shown: LineChanges.Hunk) -> Bool {
        guard let document, let changes = changesNow(), changes.hunks.contains(shown) else { NSSound.beep(); return false }
        let view = document.editor.textView
        let (range, replacement) = LineChanges.revert(shown, in: view.string)
        guard view.isEditable, view.shouldChangeText(in: range, replacementString: replacement) else { NSSound.beep(); return false }
        view.textStorage?.replaceCharacters(in: range, with: replacement)
        view.didChangeText()
        view.undoManager?.setActionName("Revert Change")
        view.setSelectedRange(NSRange(location: range.location, length: 0))
        view.reveal(range.location)
        _ = changesNow()
        Announce.sentence(Self.spoken(shown, reverted: true))
        return true
    }

    /// Text › Revert Change: the change on the caret's line.
    func revertAtCaret() {
        guard let line = caretLine, let hunk = changesNow()?.hunk(at: line) else { NSSound.beep(); return }
        revert(hunk)
    }

    /// Text › Next Change (⌃.) and Previous Change (⌃,), Sublime's keys: the caret to the start of
    /// the next change, round the end.
    func go(forward: Bool) {
        guard let document, let line = caretLine, let changes = changesNow(),
              let hunk = forward ? changes.hunk(after: line) : changes.hunk(before: line) else { NSSound.beep(); return }
        let view = document.editor.textView
        let offset = document.editor.lineIndex.start(ofLine: hunk.lines.lowerBound + 1) ?? (view.string as NSString).length
        view.setSelectedRange(NSRange(location: offset, length: 0))
        view.reveal(offset, linesAbove: 3)
        Announce.sentence(Self.spoken(hunk, reverted: false))
    }

    /// "Lines 4 to 6 changed since the last commit", for VoiceOver.
    static func spoken(_ hunk: LineChanges.Hunk, reverted: Bool) -> String {
        let lines = hunk.lines.isEmpty ? "before line \(hunk.lines.lowerBound + 1)"
            : hunk.lines.count == 1 ? "line \(hunk.lines.lowerBound + 1)" : "lines \(hunk.lines.lowerBound + 1) to \(hunk.lines.upperBound)"
        let what = hunk.lines.isEmpty ? "\(hunk.committed.count) deleted" : hunk.committed.isEmpty ? "\(lines) added" : "\(lines) changed"
        if reverted { return hunk.lines.isEmpty ? "Restored \(hunk.committed.count) line\(hunk.committed.count == 1 ? "" : "s") \(lines)" : "Reverted \(lines)" }
        return hunk.lines.isEmpty ? "Lines \(what) \(lines)" : what.prefix(1).uppercased() + what.dropFirst()
    }

    /// The repository's log of HEAD's moves: written at every commit, checkout and reset.
    private func watch(_ url: URL) {
        watcher?.cancel()
        watcher = nil
        guard let dotGit = GitRepo.dotGit(above: url), let log = GitRepo.headLog(for: dotGit) else { return }
        let descriptor = open(log.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.load() }   // read again (and watched again, if git replaced the log)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
