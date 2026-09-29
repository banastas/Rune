// The scratch file, open in nib (PRD §4). The text view holds the buffer; this
// model journals it (SY1), saves it in place with compare-and-swap (SY2-SY4),
// holds the file with an iCloud sync pause and uploads each version itself with
// fail-on-conflict (§4.3), fetches newer versions when nib becomes active (§4.4),
// reloads when the file changes and there are no edits (SY5), and merges when it
// changes while there are (§4.7): cleanly, or with both versions between conflict
// markers in the text (SY6, §5.4). Nothing is ever overwritten unseen.

import AppKit
import Network
import NibSync
import NibSyntax
import NibText
import Observation
import Security

/// Blocks written two-way, before a note could prove where both versions came from
/// (§4.6). If it arrives while the text is as written, the three-way merge replaces them.
private struct Unproven {
    var mine: ConflictText.Side
    var theirs: ConflictText.Side
    var theirsSHA: String
    var written: String
    /// What this Mac had uploaded before the merge: the note's parent must be that one (it may
    /// have uploaded the merge itself by the time the note comes; the two-Mac test at 20:55).
    var uploadedBefore: String?
}

@MainActor
@Observable
final class Document {
    let url: URL
    /// An untitled buffer (ED3): a file of Nib's own on this Mac, never synced.
    let untitled: Bool
    let device = Host.current().localizedName ?? "This Mac"
    private(set) var state: SyncState = .opening
    private(set) var format = FileFormat.standard
    /// A line that shows in the strip for a while ("▼ UPDATED FROM …", "RECOVERED …").
    private(set) var notice: String?
    /// For the strip: "MARKDOWN", "JAVASCRIPT", "PLAIN TEXT" (HL1).
    private(set) var syntaxName = "PLAIN TEXT"
    /// The syntax picked from the strip or View › Syntax, which the file keeps; nil follows
    /// the file's name and first line, which say `detectedSyntax` (nil: plain text).
    private(set) var pickedSyntax: SyntaxPick?
    /// How the file indents (ED6), found on open; for the strip ("TABS", "2 SPACES").
    private(set) var indentation: Indentation = .tabs(width: 4)
    /// The strip's line slot is a field for Go to Line (⌃G).
    var goingToLine = false
    /// Go to File or the command palette, over this window (KB2, KB3).
    var palette: PaletteSession? {
        didSet {
            if let palette { shownPalette = palette }
            // Gone: what was chosen runs when the sheet's dismissal says so, or else in a moment
            // (SwiftUI skips that call for a sheet closed while still coming in).
            if palette == nil, let old = oldValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { old.finish() }
            }
        }
    }
    @ObservationIgnored private var shownPalette: PaletteSession?
    private(set) var detectedSyntax: SyntaxLanguage?
    /// The conflict blocks in the buffer (§5.4), kept current as it changes, and the one the
    /// caret is in: ⌘1, ⌘2 and ⌘3 resolve it.
    private(set) var blocks: [ConflictBlock] = []
    private(set) var caretBlock: Int?
    /// Everything but the blocks merged (a three-way merge wrote them), for the banner.
    private(set) var mergedAroundBlocks = false
    /// Escape hides the banner until the blocks change.
    var bannerHidden = false
    /// iCloud sync is paused for the file and nib uploads it itself (§4.3).
    private(set) var held = false
    private(set) var ready = false
    /// Why the file isn't open for editing, when it isn't (the M1 safety rule, §8).
    private(set) var locked: String?
    private(set) var cursor = (line: 1, column: 1)

    let editor: Editor
    @ObservationIgnored let presenter: Presenter
    @ObservationIgnored let notePresenter: NotePresenter
    @ObservationIgnored private let journal = Journal(directory: NibPaths.support.appendingPathComponent("Journal"))
    /// Every version this Mac saved or took in, for 30 days (SY13, guarantee 2).
    @ObservationIgnored let history: History
    @ObservationIgnored private let log = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
    @ObservationIgnored private let pausedFiles = PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json"))
    @ObservationIgnored private let io = IOQueue(label: "nib.io")
    @ObservationIgnored private let journalQueue = IOQueue(label: "nib.journal")
    /// For conflict versions and duplicates: iCloud's version store can be slow, and saves
    /// mustn't queue behind it.
    @ObservationIgnored private let othersQueue = IOQueue(label: "nib.others")

    /// The version the buffer came from, or was last saved as.
    @ObservationIgnored private var baseFingerprint: Fingerprint? {
        didSet {
            guard let old = oldValue?.sha256, let new = baseFingerprint?.sha256, old != new else { return }
            superseded.insert(old)
            superseded.remove(new)
        }
    }
    /// Versions this Mac has moved past (earlier bases, by SHA-256), and when it last
    /// uploaded: just after an upload iCloud can still offer the version it replaced.
    @ObservationIgnored private var superseded: Set<String> = []
    @ObservationIgnored private var lastUpload: Date?
    @ObservationIgnored private var editCount = 0
    @ObservationIgnored private var savedEditCount = 0
    @ObservationIgnored private var schedule: SaveSchedule
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var journalTask: Task<Void, Never>?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTimer: Timer?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var uploading = false
    @ObservationIgnored private var uploadAgain = false
    @ObservationIgnored private var lastUploadStart = Date.distantPast
    @ObservationIgnored private var uploadedSHA: String?
    @ObservationIgnored private var uploadBackoff: TimeInterval = 10
    @ObservationIgnored private var lastSaved = Date()
    @ObservationIgnored private var online = true
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    /// Set while nib itself changes the buffer (a reload, a resolution), so it isn't counted as an edit.
    @ObservationIgnored private var applying = false
    /// A refresh (hand back, evict, download, hold again) is running (S1b, SY14).
    @ObservationIgnored private var refreshing = false
    /// Fetches running, each maybe putting a newer version in place: their own change to the
    /// file isn't news. A count, not a flag: fetches overlap (upload refused, coming forward,
    /// every 30 s), and one ending mustn't let the file watch deliver another's download too.
    @ObservationIgnored private var fetches = 0
    /// Announced versions already dealt with, and already in the Sync Log, by SHA-256.
    @ObservationIgnored private var handledAnnouncements: Set<String> = []
    @ObservationIgnored private var loggedAnnouncements: Set<String> = []
    /// The last note read: which version is on the server, and what it was made from.
    @ObservationIgnored private var lastNote: Announcement? { didSet { if let lastNote, lastNote.device != device { otherMac = lastNote } } }
    /// The latest note from another Mac: the menu bar panel's "other Macs" line (§5.7).
    private(set) var otherMac: Announcement?
    /// When this Mac's last upload was taken, and when it last saved (the panel's times).
    private(set) var uploadedAt: Date?
    var savedAt: Date { lastSaved }
    /// Texts of the last few versions this Mac has had, by SHA-256: merge bases (§4.6).
    @ObservationIgnored private var versions: [String: String] = [:]
    @ObservationIgnored private var versionOrder: [String] = []
    /// Other versions already taken into the buffer (merged, or written between markers):
    /// the same version arriving again isn't news (the two-Mac test at 13:22).
    @ObservationIgnored private var incorporated: Set<String> = []
    @ObservationIgnored private var unproven: Unproven?
    /// iCloud conflict versions and duplicate files already dealt with this session, and the
    /// ones whose text went into the buffer: marked resolved, or moved to the Trash, once a save
    /// has put that text in the file (§4.7).
    @ObservationIgnored private var handledOthers: Set<String> = []
    @ObservationIgnored private var pendingResolved: Set<String> = []
    @ObservationIgnored private var pendingTrash: [(url: URL, sha: String)] = []
    @ObservationIgnored private var checkingOthers = false
    /// Direct file-system watches, behind iCloud's presenters: writers that don't coordinate
    /// (`echo >> file`) went unnoticed by the presenter while a save waited to upload (M1).
    @ObservationIgnored private var fileWatch: DispatchSourceFileSystemObject?
    /// Holding again after iCloud's helper didn't answer, in the background (§4.3); a hold
    /// in flight; and closing, which waits for it so a file is never left paused.
    @ObservationIgnored private var holdRetry: Task<Void, Never>?
    /// Newer versions a fetch has brought, counted: did a refused upload's fetch find it?
    @ObservationIgnored private var newerFetched = 0
    @ObservationIgnored private var forcedRefresh: Date?
    /// A version with no proof yet of the version both had, held while its note is awaited.
    @ObservationIgnored private var waitingForNote: (sha: String, data: Data, fingerprint: Fingerprint?, source: String, fromServer: Bool)?
    @ObservationIgnored private var pausing = false
    @ObservationIgnored private var closing = false
    @ObservationIgnored private var noteWatch: DispatchSourceFileSystemObject?

    var dirty: Bool { editCount != savedEditCount }
    /// Saves and refreshes begun, for a disk check to tell whether one ran while it read the file.
    @ObservationIgnored private var saves = 0
    @ObservationIgnored private var refreshes = 0

    /// Work on this Mac that no other Mac has: unsaved edits, or, for a held file, a saved
    /// version iCloud hasn't taken yet. Only a buffer with nothing unsent may be replaced by
    /// another version; anything else is merged with it. (Two-Mac test, 09:25: a
    /// saved-but-refused version counted as clean and was replaced, losing its line.) A version
    /// saved while the file was held stays unsent if the hold is lost before it's uploaded:
    /// the suite (2026-09-29, `refusal`) lost a hold a moment after the previous launch handed
    /// the file back, iCloud then put the server's older copy in the file, and the buffer,
    /// thought clean, took it, the typing left only in the journal.
    var unsent: Bool {
        dirty || (uploadedSHA != baseFingerprint?.sha256 && (held || (savedWhileHeld != nil && savedWhileHeld == baseFingerprint?.sha256)))
    }
    /// The last version saved while the file was held (§4.3).
    @ObservationIgnored private var savedWhileHeld: String?

    init(url: URL) {
        self.url = url
        untitled = Untitled.contains(url)
        let defaults = UserDefaults.standard
        schedule = SaveSchedule(idle: defaults.object(forKey: "NibSaveIdle") as? TimeInterval ?? 1,
                                maxWait: defaults.object(forKey: "NibSaveMax") as? TimeInterval ?? 5)
        presenter = Presenter(url: url)
        notePresenter = NotePresenter(note: Announcement.url(for: url))
        history = History(root: NibPaths.support.appendingPathComponent("History"), path: url.path)
        editor = Editor()
        presenter.document = self
        notePresenter.document = self
        editor.document = self
    }

    // MARK: - Opening

    func open() async {
        if let reason = ScratchLocation.refusal(for: url) {
            locked = reason
            state = .problem(reason)
            editor.textView.isEditable = false
            return
        }
        let url = self.url
        let presenter = self.presenter
        if ScratchLocation.inContainer(url) {
            // Sets up nib's iCloud folder on first use; false when iCloud Drive is off. iCloud may not
            // answer at all: then, with the file already here, open it anyway.
            let container = await CloudControl.containerAvailable(ScratchLocation.containerID, within: 10)
            if container == nil { record("open", detail: "iCloud didn't answer about Nib's folder in 10 s: opening the file anyway") }
            guard container != false, container == true || FileManager.default.fileExists(atPath: url.path) else {
                state = .problem("NIB'S ICLOUD FOLDER ISN'T AVAILABLE · IS ICLOUD DRIVE ON? · NOTHING WAS OPENED")
                record("problem", detail: "url(forUbiquityContainerIdentifier:) returned nil")
                return
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                if case .written(let fingerprint) = try await io.run({ try FileAccess.write(Data(), to: url, base: nil, presenter: presenter) }) {
                    baseFingerprint = fingerprint
                    record("open", size: 0, sha: fingerprint.sha256, detail: "created")
                }
            } catch {
                state = .problem("COULDN'T CREATE \(url.lastPathComponent.uppercased()) · \(short(error))")
                record("problem", detail: "create: \(CloudControl.describe(error))")
                return
            }
        }
        // iCloud may not answer (its file provider can stall): then open it anyway, and hold it once
        // iCloud answers (the background retry).
        let answered = await CloudControl.status(url, within: 10)
        if answered == nil { record("open", detail: "iCloud didn't say how the file stands in 10 s: opening it anyway, and holding it once iCloud answers") }
        let status = answered ?? CloudControl.Status()
        if status.downloadStatus == "notDownloaded" {
            state = .notDownloaded
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var text = ""
        do {
            let (data, fingerprint) = try await io.run { try FileAccess.read(url, presenter: presenter) }
            let decoded = TextFile.decode(data)
            text = decoded.text
            format = decoded.format
            baseFingerprint = fingerprint
            remember(text, sha: fingerprint.sha256)
            recordHistory { history in try? history.record(data, parent: nil, source: "opened") }
        } catch {
            state = .problem("COULDN'T READ \(url.lastPathComponent.uppercased()) · \(short(error))")
            record("problem", detail: CloudControl.describe(error))
            return
        }
        applying = true
        editor.textView.string = text
        applying = false
        editor.restoreSelection(for: url)
        updateBlocks()
        if !untitled {
            NSFileCoordinator.addFilePresenter(presenter)
            try? FileManager.default.createDirectory(at: Announcement.url(for: url).deletingLastPathComponent(), withIntermediateDirectories: true)
            NSFileCoordinator.addFilePresenter(notePresenter)
            watchFile()
            watchNoteFolder()
        }
        record("open", size: text.utf8.count, sha: baseFingerprint?.sha256)
        recoverFromJournal(fileText: text)
        pickedSyntax = UserDefaults.standard.string(forKey: "syntax:" + url.path).flatMap(SyntaxPick.init(stored:))
        applySyntax()
        indentation = Indentation.detect(in: editor.textView.string, fallback: Self.defaultIndentation)
        editor.indentation = indentation
        state = untitled ? .local(Date()) : status.uploaded ? .synced(Date()) : .saved(Date())
        ready = true
        if untitled {
            // Nothing to hold, fetch or announce: it's on this Mac only.
            let history = self.history
            Task { await journalQueue.run { history.thin() } }
            if dirty { scheduleSave() }
            return
        }
        watchNetwork()
        if answered == nil { scheduleHoldRetry() } else { await hold(status) }
        if held {
            // Paused, iCloud's uploaded flag stops meaning anything (M0). A file left paused
            // by a crash may hold saves iCloud never got: upload it before trusting it.
            if status.uploaded, status.paused != true {
                uploadedSHA = baseFingerprint?.sha256
            } else {
                await upload(now: true)
            }
        }
        await fetchLatest(reason: "open")
        await checkAnnouncement(reason: "open")
        await checkOthers(reason: "open")
        let history = self.history
        Task { await journalQueue.run { history.thin() } }
        if dirty { scheduleSave() }
    }

    /// A journal newer than the file means the last session ended before it saved (§4.8 G).
    private func recoverFromJournal(fileText: String) {
        guard let entry = journal.read(path: url.path) else { return }
        guard entry.text != fileText else { journal.clear(path: url.path); return }
        if entry.baseSHA256 == baseFingerprint?.sha256 {
            // The file hasn't changed since those edits began: they simply win.
            applying = true
            editor.textView.string = entry.text
            applying = false
            // The file's blocks were found in the file's text: find them again in this one. Left
            // as they were, the text view drew frames from ranges past the end of the text, and
            // Nib crashed or hung at every launch while that journal waited (the suite, 2026-09-29).
            updateBlocks()
            editCount += 1
            show("RECOVERED TYPING FROM BEFORE NIB QUIT UNEXPECTEDLY · SAVING IT NOW", for: 20)
            record("recover", size: entry.text.utf8.count, detail: "journal from \(entry.written)")
        } else {
            // The file changed too: both versions between markers, and typing goes on (§4.8 B).
            let both = ConflictText.keepBoth(.init(text: entry.text, label: "\(device) · \(SyncState.clock.string(from: entry.written))"),
                                             .init(text: fileText, label: "The file · now"))
            editCount += 1
            applying = true
            editor.textView.string = both
            applying = false
            updateBlocks()
            show("✕ TYPING FROM BEFORE NIB QUIT, AND A NEWER FILE · BOTH ARE IN THE TEXT, BETWEEN MARKERS", for: 20)
            record("conflict", detail: "journal and file both changed: both written between markers")
        }
    }

    /// Pauses iCloud's own syncing of the file, when iCloud offers it (§4.3). Only a real
    /// conflict takes the server's version; iCloud's other answers can be passing (§8, the
    /// suite run after 20:25), so they never leave the file unheld for the session.
    private func hold(_ status: CloudControl.Status) async {
        guard status.ubiquitous, status.canPause, status.canFailOnConflict else {
            record("pause", detail: "not offered: iCloud uploads on its own schedule")
            return
        }
        if status.paused == true {
            // Left paused by an earlier session (a crash, or a quit that didn't finish). Pausing
            // again answers "not supported" (M1), so take it back first, then hold it fresh. The
            // file may hold saves iCloud never got: upload them, refusing to overwrite a newer one.
            do {
                try await resumeFile(.uploadFailingOnConflict)
                record("resume", detail: "left paused by an earlier session; its saves are uploaded")
            } catch where CloudControl.isConflict(error) {
                // The server has something newer. Keep what's here as edits, take the server's
                // version, and merge the two (with no proven base: both, between markers).
                let leftover = editor.textView.string
                try? await resumeFile(.takeServerVersion)
                record("resume", detail: "left paused with unsent saves, and the server has a newer version: \(CloudControl.describe(error))")
                let presenter = self.presenter
                let url = self.url
                if let (data, fingerprint) = try? await io.run({ try FileAccess.read(url, presenter: presenter) }),
                   TextFile.decode(data).text != leftover {
                    editCount += 1   // the leftover counts as edits, so it's merged, not dropped
                    incoming(data, fingerprint: fingerprint, from: "iCloud", fromServer: true)
                }
            } catch where CloudControl.isUnsupported(error) {
                // "Not supported": it isn't paused after all (iCloud's status a moment behind a
                // hand-back just before). Hold it fresh, below.
                record("resume", detail: "iCloud said paused, but it wasn't (a hand-back a moment before): holding it fresh")
            } catch {
                // Passing (iCloud's helper not answering): the pause is still this Mac's own.
                held = true
                pausedFiles.add(url.path)
                record("pause", detail: "left paused by an earlier session, and handing it back failed (\(CloudControl.describe(error))): holding it as it is")
                return
            }
        }
        do {
            let waited = try await pauseFile()
            held = true
            pausedFiles.add(url.path)
            record("pause", detail: Self.uploadWait(waited))
            checkHoldLasts()
        } catch is CancellationError {
            return   // closed while waiting for the upload: nothing to hold, nothing to hand back
        } catch {
            if await heldAlready(error) { return }
            record("pause", detail: "not held yet: \(Self.pauseTrouble(error)); trying again in 2 s")
            scheduleHoldRetry()
        }
    }

    /// Pausing answered "not supported" and the file is in fact paused: this Mac's own pause
    /// (pausing a paused file answers so, M1), so it's held as it is.
    private func heldAlready(_ error: Error) async -> Bool {
        let url = self.url
        guard (error as? CloudControl.ControlError) == .unsupported, await CloudControl.status(url, within: 10)?.paused == true else { return false }
        held = true
        pausedFiles.add(url.path)
        record("pause", detail: "already paused, by this Mac: holding it as it is")
        return true
    }

    static func pauseTrouble(_ error: Error) -> String {
        (error as? CloudControl.ControlError) == .unsupported
            ? "iCloud answered \"not supported\" (it can, a moment after a hand-back)" : CloudControl.describe(error)
    }

    /// Hands the file back to iCloud (or, in tests, fails as iCloud's helper can).
    private func resumeFile(_ mode: CloudControl.ResumeMode) async throws {
        #if DEBUG
        if TestHarness.failResumes > 0 {
            TestHarness.failResumes -= 1
            throw NSError(domain: NSCocoaErrorDomain, code: 4099, userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application. (a test)"])
        }
        #endif
        try await CloudControl.resume(url, mode)
    }

    /// Pauses iCloud's syncing of the file, once iCloud has finished uploading it. Pausing a
    /// file mid-upload crashes iCloud's file provider (macOS 27.0.1: 36 crash reports in two
    /// days, each in its pause handler, each for a file just written, just rewritten, or just
    /// handed back with an upload to make); Nib saw "Couldn't communicate with a helper
    /// application", and every app's iCloud Drive waited until the provider came back (once,
    /// for more than ten minutes). A failed hold is tried again in the background: 2, 5, 10, 20
    /// and 40 s later, then every minute while the file is open. Meanwhile it runs unheld,
    /// synced by iCloud on its own schedule, and Nib's saves go on as before.
    /// A re-hold of a file Nib is holding (after a refresh) doesn't wait: unpaused while it
    /// waited, iCloud put the server's copy back over Nib's (the suite, 2026-09-29). Returns
    /// how long it waited for the upload, in seconds.
    @discardableResult
    private func pauseFile(waitingForUpload wait: Bool = true) async throws -> Double {
        pausing = true
        defer { pausing = false }
        #if DEBUG
        if TestHarness.failPauses > 0, let prefix = TestHarness.failPausesFor, url.lastPathComponent.hasPrefix(prefix) {
            TestHarness.failPauses -= 1
            throw NSError(domain: NSCocoaErrorDomain, code: 4099, userInfo: [NSLocalizedDescriptionKey: "Couldn't communicate with a helper application. (a test)"])
        }
        if TestHarness.unsupportedPauses > 0, let prefix = TestHarness.failPausesFor, url.lastPathComponent.hasPrefix(prefix) {
            TestHarness.unsupportedPauses -= 1
            throw CloudControl.ControlError.unsupported
        }
        #endif
        let waited = wait ? try await waitForUpload() : 0
        try await CloudControl.pause(url)
        return waited
    }

    /// Until iCloud isn't uploading the file (checked every quarter second, for up to 15 s: a
    /// 30 KB file took 3 s), or it stops answering; closing ends the wait, and the hold.
    private func waitForUpload(limit: Double = 15) async throws -> Double {
        let url = self.url, started = Date()
        while Date().timeIntervalSince(started) < limit {
            guard !closing else { throw CancellationError() }
            guard let status = await CloudControl.status(url, within: 5) else { break }
            // A paused file doesn't upload; one iCloud doesn't sync has nothing to wait for.
            guard status.paused != true, status.ubiquitous, status.uploading || !status.uploaded else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !closing else { throw CancellationError() }
        return Date().timeIntervalSince(started)
    }

    /// A pause made a moment after another launch handed the file back can be undone by that
    /// hand-back finishing (the suite, `refusal-lost-hold`, twice): 3 s on, is it still paused?
    /// If not, it's held again, and whatever iCloud put in the file meanwhile is looked at.
    private func checkHoldLasts() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.held, !self.closing, !self.refreshing else { return }
            let url = self.url
            guard await CloudControl.status(url, within: 5)?.paused == false else { return }
            self.record("pause", detail: "the hold didn't last (a hand-back a moment before, finishing): holding it again")
            self.held = false
            await self.holdAgain()
            await self.diskMayHaveChanged()
        }
    }

    /// "after its upload (3.1 s)", when the hold waited for one.
    private static func uploadWait(_ seconds: Double) -> String? {
        seconds >= 0.5 ? "after its upload (\(seconds.formatted(.number.precision(.fractionLength(1)))) s)" : nil
    }

    private func scheduleHoldRetry() {
        guard holdRetry == nil, !closing, !untitled else { return }
        holdRetry = Task { [weak self] in
            let started = Date(), delays: [Double] = [2, 5, 10, 20, 40]
            var tries = 1
            while true {
                try? await Task.sleep(for: .seconds(tries <= delays.count ? delays[tries - 1] : 60))
                guard let self, !Task.isCancelled, !self.closing, !self.held else { return }
                tries += 1
                if await self.retryHold(tries: tries, since: started) { break }
                if tries == delays.count + 1 {
                    self.record("pause", detail: "still failing after \(tries) tries: running unheld, trying every minute while it's open")
                }
            }
            self?.holdRetry = nil
        }
    }

    /// One more try at holding the file; true once it's held or iCloud stops offering it.
    private func retryHold(tries: Int, since: Date) async -> Bool {
        guard !saving, !refreshing, fetches == 0 else { return false }   // not in the middle of those: next time
        await diskMayHaveChanged()   // whatever iCloud put there while it wasn't held
        let url = self.url
        guard let status = await CloudControl.status(url, within: 10) else { return false }   // not answering: next time
        guard status.ubiquitous, status.canPause, status.canFailOnConflict else {
            record("pause", detail: "not offered any more: iCloud uploads on its own schedule")
            return true
        }
        do {
            try await pauseFile()
        } catch {
            return await heldAlready(error)   // otherwise, "not supported" included: next time
        }
        held = true
        pausedFiles.add(url.path)
        record("pause", ms: ms(since: since), detail: "held on try \(tries)")
        guard !closing else { return true }   // closing waits for this, then hands it back
        // iCloud may not have the latest save: upload it, refused if the server has a newer
        // version, which is then merged (§4.3, §4.6), as when a file is first held.
        await upload(now: true)
        await checkAnnouncement(reason: "held")
        return true
    }

    // MARK: - Editing

    /// From the editor, for every change the user makes.
    func textDidChange() {
        updateBlocks()
        guard !applying, locked == nil else { return }
        editedHere = true
        editCount += 1
        schedule.edited()
        state = .editing
        scheduleJournal()
        scheduleSave()
    }

    func selectionDidChange(line: Int, column: Int) {
        cursor = (line, column)
        updateCaretBlock()
    }

    // MARK: - Conflict blocks (§5.4)

    /// Finds the blocks again after any change to the buffer (a scan, and only when a
    /// marker is there at all: a few ms at 2.4 MB).
    private func updateBlocks() {
        // With no blocks, only an edit on a marker line can make one: don't search the whole
        // text on every keystroke (14 ms at 2.4 MB).
        if blocks.isEmpty, let edit = editor.lastEdit, let storage = editor.textView.textStorage {
            let text = storage.string as NSString
            let lines = text.lineRange(for: NSIntersectionRange(edit, NSRange(location: 0, length: text.length)))
            guard ["<<<<<<<", "|||||||", "=======", ">>>>>>>"].contains(where: { text.range(of: $0, range: lines).location != NSNotFound }) else { return }
        }
        let found = ConflictText.blocks(in: editor.textView.string)
        if found.count != blocks.count { bannerHidden = false }
        if found != blocks { blocks = found }
        if blocks.isEmpty { mergedAroundBlocks = false }
        editor.highlight(blocks)
        updateCaretBlock()
    }

    private func updateCaretBlock() {
        let inside = editor.block(atCaretIn: blocks)
        if inside != caretBlock { caretBlock = inside }
    }

    // The Conflicts menu acts on the merge view's result while it's open, else on the buffer.

    /// Where ⌘1, ⌘2, ⌘3 would act: the merge view's result's caret block, or the buffer's.
    var activeCaretBlock: ConflictBlock? {
        if let merge { return merge.caretBlock.map { merge.blocks[$0] } }
        return caretBlock.flatMap { $0 < blocks.count ? blocks[$0] : nil }
    }
    var activeBlockCount: Int { merge?.blocks.count ?? blocks.count }

    /// ⌘1, ⌘2, ⌘3 with the caret in a block: an edit like typing (journaled, saved, one undo step).
    func resolveBlock(_ choice: ConflictBlock.Choice) {
        if let merge { merge.resolve(choice); return }
        guard let index = caretBlock, index < blocks.count else { NSSound.beep(); return }
        let label = editor.resolve(blocks[index], choice)
        record("resolve", detail: choice == .both ? "a block: both" : "a block: \(label)'s")
    }

    /// ⌥⌘↓ and ⌥⌘↑: the caret to the next (or previous) block.
    func goToBlock(forward: Bool) {
        if let merge { merge.editor.go(forward: forward, in: merge.blocks); return }
        editor.go(forward: forward, in: blocks)
    }

    /// Resolve… (⌥⌘R): the merge view for more than three blocks (§5.5), else the next block.
    func resolveConflicts() {
        if merge == nil, blocks.count > 3 { openMerge() } else { goToBlock(forward: true) }
    }

    // MARK: - The merge view (§5.5)

    /// The open merge view, if any.
    private(set) var merge: MergeSession?

    func openMerge() {
        guard merge == nil, !blocks.isEmpty else { NSSound.beep(); return }
        merge = MergeSession(text: editor.textView.string, device: device, syntax: editor.syntax)
        record("merge view", detail: "opened on \(blocks.count) block\(blocks.count == 1 ? "" : "s")")
    }

    /// Done: the result into the buffer as one edit. If the buffer changed while the sheet was up
    /// (another Mac's version arrived), the two are merged from where the sheet started, so
    /// nothing that came meanwhile is lost. Cancel: nothing changes; the markers stay.
    func closeMerge(done: Bool) {
        guard let session = merge else { return }
        merge = nil
        guard done else { record("merge view", detail: "cancelled; the blocks stay in the text"); return }
        let now = editor.textView.string
        var result = session.result
        if now != session.original {
            let clock = SyncState.clock.string(from: Date())
            result = Merge.threeWay(base: session.original, .init(text: result, label: "Merge view · \(clock)"),
                                    .init(text: now, label: "\(device) · \(clock)")).text
        }
        guard result != now else { return }
        replaceBuffer(with: result, action: "Merge View")
        let left = ConflictText.blocks(in: result).count
        record("merge view", detail: "done: \(session.total - min(left, session.total)) of \(session.total) resolved" + (now != session.original ? ", merged with what arrived meanwhile" : ""))
    }

    /// Escape: the banner goes until the blocks change. False if it wasn't showing.
    func hideBanner() -> Bool {
        guard !blocks.isEmpty, !bannerHidden else { return false }
        bannerHidden = true
        return true
    }

    private func scheduleJournal() {
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.writeJournal()
        }
    }

    private func writeJournal() async {
        let entry = JournalEntry(path: url.path, text: editor.textView.string,
                                 baseSHA256: baseFingerprint?.sha256, format: format)
        let journal = self.journal
        do {
            try await journalQueue.run { try journal.write(entry) }
        } catch {
            // The one case where text lives only in memory (§4.9, 13): say so loudly.
            state = .problem("COULDN'T WRITE THE RECOVERY JOURNAL · \(short(error)) · YOUR LATEST TYPING IS ONLY IN MEMORY")
            record("problem", detail: "journal: \(CloudControl.describe(error))")
        }
    }

    private func scheduleSave(after delay: TimeInterval? = nil) {
        saveTask?.cancel()
        let wait = delay ?? max(0, (schedule.due ?? Date()).timeIntervalSinceNow)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.save(reason: "debounce")
        }
    }

    // MARK: - Saving

    /// Saves now and uploads now (§4.3 step 3): focus loss, app switch, sleep, lock, ⌘S, quit.
    /// Typed in, this session: tidying on ⌘S touches only files the user edited (ED6).
    @ObservationIgnored private(set) var editedHere = false

    /// ⌘S: tidied first (ED6: trailing whitespace, a final newline, as Settings › Editor says,
    /// and only in a file edited here), then saved and uploaded now.
    func saveNow() async {
        tidyForSave()
        await flush(reason: "⌘S")
    }

    /// The ⌘S tidy, as one change ⌘Z undoes; the strip says what it did. Never on Nib's own
    /// saves: a second after typing stops, it would take a space just typed.
    func tidyForSave() {
        let defaults = UserDefaults.standard
        let trim = defaults.bool(forKey: "saveTrimsTrailingWhitespace"), newline = defaults.bool(forKey: "saveEnsuresFinalNewline")
        guard trim || newline, editedHere, locked == nil else { return }
        let view = editor.textView
        let result = SaveTidy.tidy(view.string, selection: view.selectedRange(), trimTrailing: trim, finalNewline: newline)
        guard let edit = result.edit else { return }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        view.didChangeText()
        view.undoManager?.setActionName(result.trimmedLines > 0 && result.addedNewline ? "Trim Whitespace and Add Newline"
                                        : result.addedNewline ? "Add Final Newline" : "Trim Trailing Whitespace")
        view.setSelectedRange(edit.selection)
        var facts: [String] = []
        if result.trimmedLines > 0 { facts.append("TRIMMED TRAILING WHITESPACE ON \(result.trimmedLines) LINE\(result.trimmedLines == 1 ? "" : "S")") }
        if result.addedNewline { facts.append("ADDED A FINAL NEWLINE") }
        show((facts + ["⌘Z UNDOES"]).joined(separator: " · "), for: 6)
    }

    func flush(reason: String) async {
        guard ready, locked == nil else { return }
        saveTask?.cancel()
        // A save already running (the app switch's, say) would make this one step aside and
        // return before the file has the text: wait for it, then save what's still unsaved.
        for _ in 0..<250 where saving { try? await Task.sleep(for: .milliseconds(20)) }
        if dirty { await save(reason: reason) }
        if held, uploadedSHA != baseFingerprint?.sha256 { await upload(now: true) }
    }

    func save(reason: String) async {
        guard ready, locked == nil, dirty else { return }
        if editor.textView.hasMarkedText() {   // mid-composition (IME): wait for the commit
            scheduleSave(after: 0.3)
            return
        }
        guard !saving else { scheduleSave(after: 0.2); return }
        // Not while the file is being refreshed (a save then went into a file being evicted,
        // at 20:55), nor while a merge waits for a note (the file holds the other version).
        guard !refreshing, waitingForNote == nil else { scheduleSave(after: 0.5); return }
        saving = true
        saves += 1
        var uploadNow: Bool?
        let text = editor.textView.string
        let snapshot = editCount
        let data = TextFile.encode(text, as: format)
        let base = baseFingerprint
        let url = self.url
        let presenter = self.presenter
        let started = Date()
        do {
            let outcome = try await io.run { try FileAccess.write(data, to: url, base: base, presenter: presenter) }
            switch outcome {
            case .written(let fingerprint):
                baseFingerprint = fingerprint
                if held { savedWhileHeld = fingerprint.sha256 }
                remember(text, sha: fingerprint.sha256)
                recordHistory { history in try? history.record(data, parent: base?.sha256, source: "saved") }
                if !pendingResolved.isEmpty || !pendingTrash.isEmpty { settleOthers() }
                savedEditCount = snapshot
                lastSaved = Date()
                if !dirty {
                    schedule.saved()
                    journal.clear(path: url.path)
                }
                state = dirty ? .editing : untitled ? .local(lastSaved) : .saved(lastSaved)
                record("save", size: data.count, sha: fingerprint.sha256, ms: ms(since: started), detail: reason)
                uploadNow = reason != "debounce"
            case .diskChanged(let onDisk, let fingerprint):
                record("save", detail: "refused: the file changed on disk since it was loaded")
                saving = false
                incoming(onDisk, fingerprint: fingerprint, from: "the file")
                if dirty { scheduleSave() }   // what's still unsaved: saved again (it sat unsaved until quit at 20:55)
                return
            }
        } catch {
            state = .problem("COULDN'T SAVE \(url.lastPathComponent.uppercased()) · \(short(error)) · YOUR TEXT IS IN NIB'S RECOVERY JOURNAL")
            record("problem", detail: "save: \(CloudControl.describe(error))")
            saving = false
            scheduleSave(after: 15)
            return
        }
        saving = false
        if dirty { scheduleSave() }
        if let uploadNow { await upload(now: uploadNow) }
    }

    // MARK: - Uploading (held files, §4.3 step 7)

    /// At most every 3 s while typing continues, one at a time; `now` skips the spacing.
    private func upload(now: Bool) async {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "NibHoldUploads") { return }   // the "unsent" scenario
        #endif
        guard held, online || now else {
            if held, !online { state = .waiting("WAITING FOR NETWORK · SAVED LOCALLY \(SyncState.clock.string(from: lastSaved))") }
            return
        }
        guard !uploading else { uploadAgain = true; return }
        guard !refreshing else {
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.upload(now: now)
            }
            return
        }
        let spacing = now ? 0 : max(0, 3 - Date().timeIntervalSince(lastUploadStart))
        if spacing > 0 {
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(spacing))
                guard !Task.isCancelled else { return }
                await self?.upload(now: true)
            }
            return
        }
        uploading = true
        lastUploadStart = Date()
        let sha = baseFingerprint?.sha256
        if !dirty { state = .uploading(lastSaved) }
        let started = Date()
        do {
            #if DEBUG
            if TestHarness.refuseUploads > 0 {   // the `refusal` scenario: as when another Mac uploaded first
                TestHarness.refuseUploads -= 1
                try? await Task.sleep(for: .seconds(1))
                throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSFileProviderErrorDomain", code: -2015)])
            }
            #endif
            _ = try await CloudControl.upload(url)
            let parent = uploadedSHA
            uploadedSHA = sha
            lastUpload = Date()
            uploadedAt = lastUpload
            uploadBackoff = 10
            record("upload", sha: sha, ms: ms(since: started))
            if let sha { announce(sha, parent: parent) }
            if !dirty, baseFingerprint?.sha256 == sha { state = .synced(Date()) }
        } catch where CloudControl.isConflict(error) {
            record("upload", ms: ms(since: started), detail: "refused: the server has a newer version")
            uploading = false
            // Closing: the quit's own hand-back deals with it (journal, then the server's version);
            // a fetch or refresh now would run alongside it (a suite run at 21:20).
            guard !closing else { return }
            let fetched = newerFetched
            await fetchLatest(reason: "upload refused")
            // The refusal proves the server has a newer version, but iCloud can still answer
            // "nothing newer" for a held file (§4.4; the two-Mac test at 20:02: 48 s with the other
            // Mac's line nowhere, until this Mac came forward). Then a forced refresh fetches it:
            // the file is handed back taking the server's version, and the buffer's text, kept
            // in the journal meanwhile, is merged with it. Not with unsaved typing: its own save's
            // upload is refused in turn and comes back here.
            if newerFetched == fetched, !dirty, !saving, !refreshing {
                if let last = forcedRefresh, Date().timeIntervalSince(last) < 20 {
                    // One forced refresh at most every 20 s, should iCloud keep answering stale.
                    record("fetch", detail: "iCloud says there's nothing newer, but it refused the upload: trying the upload again in 20 s")
                    uploadTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(20))
                        guard !Task.isCancelled else { return }
                        await self?.upload(now: true)
                    }
                } else {
                    forcedRefresh = Date()
                    record("fetch", detail: "iCloud says there's nothing newer, but it refused the upload: refreshing")
                    await writeJournal()
                    await refresh(announced: lastNote)
                }
            }
            return
        } catch where CloudControl.isUnsupported(error) {
            // "Not supported": this upload is for a paused file, and the file isn't paused. The
            // hold was lost (the suite, `refusal-lost-hold`: paused a second after the launch
            // before handed the file back, and every upload after answered this until quit):
            // hold it again and upload, the work still unsent.
            record("upload", ms: ms(since: started), detail: "failed: \(CloudControl.describe(error)); the file isn't held any more: holding it again")
            uploading = false
            if await CloudControl.status(url, within: 5)?.paused != true {
                held = false
                await holdAgain()
            }
            if held {
                await diskMayHaveChanged()   // whatever iCloud put there meanwhile
                uploadTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    await self?.upload(now: true)
                }
            }
            return
        } catch {
            let noAnswer = CloudControl.isNoAnswer(error)
            record("upload", ms: ms(since: started), detail: noAnswer ? "no answer in 15 s; retrying" : "failed: \(CloudControl.describe(error))")
            state = .waiting(!online ? "WAITING FOR NETWORK · SAVED LOCALLY"
                             : noAnswer ? "ICLOUD ISN'T ANSWERING · SAVED LOCALLY · RETRYING"
                             : "ICLOUD ISN'T TAKING UPLOADS · SAVED LOCALLY · RETRYING")
            // No answer: retry soon; the retry is typically refused or accepted at once.
            let delay = noAnswer ? 2 : uploadBackoff
            uploadBackoff = min(uploadBackoff * 2, 300)
            uploadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.upload(now: true)
            }
            uploading = false
            return
        }
        uploading = false
        if uploadAgain || (uploadedSHA != baseFingerprint?.sha256 && !dirty) {
            uploadAgain = false
            await upload(now: false)
        }
    }

    // MARK: - Incoming versions

    /// A held file doesn't download by itself: ask the server (§4.4).
    func fetchLatest(reason: String) async {
        guard ready, locked == nil, !closing, !refreshing else { return }   // a refresh brings the newest anyway
        guard held else { await diskMayHaveChanged(); return }
        guard !uploading else { return }   // the upload itself is refused if the server is newer
        let url = self.url
        fetches += 1
        defer { fetches -= 1 }
        do {
            // Within 30 s of this Mac's own upload (as of iCloud's answer), a version it has already
            // moved past is iCloud lagging, not news (the two-Mac test at 14:20 showed an old
            // version for 24 s). Later it's taken as before; another Mac going back to it comes
            // with its note anyway.
            var result = try await CloudControl.fetchLatest(url, skipping: { [weak self] in
                await MainActor.run { self?.staleVersions() ?? [] }
            })
            #if DEBUG
            if TestHarness.staleFetches > 0 { TestHarness.staleFetches -= 1; result = .current }   // iCloud saying "nothing newer"
            if let data = TestHarness.fakeNewer {   // another Mac's version, put in place as a fetch does
                TestHarness.fakeNewer = nil
                try? data.write(to: url)
                result = .newer(data: data, savedBy: nil, modified: Date())
            }
            #endif
            switch result {
            case .skipped(let sha):
                record("fetch", sha: sha, detail: "iCloud offered a version this Mac had moved past, just after uploading: left as is (\(reason))")
                fallthrough
            case .current:
                // Nothing newer anywhere, and iCloud has what's here: synced.
                if !dirty, !uploading, uploadedSHA != nil, uploadedSHA == baseFingerprint?.sha256 {
                    state = .synced(Date())
                }
            case .newer(let data, let savedBy, _):
                newerFetched += 1
                let fingerprint = try? await io.run { () -> Fingerprint in
                    var fingerprint = try FileAccess.stat(url)
                    fingerprint.sha256 = Digest.sha256(data)
                    return fingerprint
                }
                // After an upload iCloud offers this Mac's own version back; it's put in place all
                // the same (the next upload needs it), but it isn't another Mac's.
                let own = fingerprint?.sha256 != nil && fingerprint?.sha256 == baseFingerprint?.sha256
                record("fetch", size: data.count, sha: fingerprint?.sha256,
                       detail: own ? "this Mac's own version back from iCloud (\(reason))" : "newer\(savedBy.map { ", iCloud says saved by \($0)" } ?? "") (\(reason))")
                // Replacing the local file may have ended the pause: hold it again, at once (not
                // after an upload: unpaused, iCloud put the server's copy back over it, M2).
                if await CloudControl.status(url, within: 5)?.paused != true {
                    try? await CloudControl.pause(url)
                }
                // Which Mac saved it: the note, when it names this version. iCloud's own answer
                // can name the wrong Mac (at 20:25 it named the Air for the Mac mini's version, on
                // the Air), and a note can be this Mac's own: then just "another Mac" (W2).
                let note = await io.run { Announcement.read(for: url) }
                if let note { lastNote = note }
                let who = note.flatMap { $0.sha256 == fingerprint?.sha256 && $0.device != device ? $0.device : nil } ?? "another Mac"
                incoming(data, fingerprint: fingerprint, from: who, fromServer: true)
            }
        } catch {
            record("fetch", detail: "failed (\(reason)): \(CloudControl.describe(error))")
        }
    }

    /// The presenter or a check found the file different: look at what's there (§4.4 Check).
    func diskMayHaveChanged() async {
        guard ready, locked == nil, !saving, !refreshing, fetches == 0 else { return }
        let url = self.url
        let presenter = self.presenter
        let saves = self.saves, refreshes = self.refreshes
        guard FileManager.default.fileExists(atPath: url.path),
              let current = try? await io.run({ try FileAccess.stat(url) }) else { return }
        if let base = baseFingerprint, current.sameStat(as: base) { return }
        guard let (data, fingerprint) = try? await io.run({ try FileAccess.read(url, presenter: presenter) }) else { return }
        // A save began meanwhile: what was read may be that save's own write, before the save
        // took it as the base (the suite, 2026-09-29: Nib merged its own saves with its buffer
        // 30 times over). The save's compare-and-swap sees any other change; a later one comes
        // with its own notice.
        // Nor after a refresh began: it ends by looking at the file itself, and this read may be
        // from before it, its answer acted on while the hold was down (the suite, `refusal`:
        // the buffer, thought clean, took the server's older copy).
        guard saves == self.saves, refreshes == self.refreshes, !saving, !refreshing else { return }
        if fingerprint.sha256 == baseFingerprint?.sha256 {
            baseFingerprint = fingerprint
            return
        }
        record("reload", size: data.count, sha: fingerprint.sha256, detail: "the file changed on disk")
        incoming(data, fingerprint: fingerprint, from: held ? "another app" : "iCloud")
    }

    /// A version nib didn't write. No local edits: it replaces the buffer. Edits: a conflict.
    private func incoming(_ data: Data, fingerprint: Fingerprint?, from source: String, fromServer: Bool = false, noteWaited: Bool = false) {
        // Not news: the version the buffer's edits start from, or one already taken in (merged,
        // or between markers). The two-Mac test at 13:22 merged one version twice, then its own save.
        if let sha = fingerprint?.sha256 {
            if waitingForNote?.sha == sha {
                // The version a merge waits on a note for, seen again: the file holds it, and a
                // disk check took it for another app's, merging at once with no note (the suite,
                // 2026-09-29). The wait decides.
                return
            }
            if incorporated.contains(sha) {
                record("reload", sha: sha, detail: "from \(source): a version already taken in, left as is")
                return
            }
            if sha == baseFingerprint?.sha256 {
                baseFingerprint = fingerprint
                if fromServer { uploadedSHA = sha }
                return
            }
            if sha == uploadedSHA, unsent {
                // The version this Mac last uploaded, which its unsent work starts from (a stale
                // answer, or a refresh after a refusal bringing just that): nothing to merge. It's
                // what's in the file now, so the buffer is saved over it again and uploaded.
                record("reload", sha: sha, detail: "from \(source): the version this Mac last uploaded, which its unsent work starts from; saving that work again")
                baseFingerprint = fingerprint
                editCount += 1
                scheduleSave(after: 0)
                return
            }
        }
        let theirs = TextFile.decode(data).text
        remember(theirs, sha: fingerprint?.sha256)
        recordHistory { history in try? history.record(data, parent: nil, source: "from \(source)") }
        let mine = editor.textView.string
        if theirs == mine {
            baseFingerprint = fingerprint
            savedEditCount = editCount
            if fromServer { uploadedSHA = fingerprint?.sha256 }
            return
        }
        if !unsent {
            apply(theirs)
            record("update", sha: fingerprint?.sha256, detail: "nothing unsent here: the buffer is now \(source)'s version")
            baseFingerprint = fingerprint
            show("▼ UPDATED FROM \(source.uppercased()) · \(SyncState.clock.string(from: Date()))", for: 10)
            if fromServer {
                uploadedSHA = fingerprint?.sha256
                state = .synced(Date())
            } else {
                // Another app on this Mac wrote a held file: iCloud won't upload it, nib does.
                state = .saved(Date())
                Task { await upload(now: true) }
            }
            return
        }
        // Made from the version this Mac last had on the server, as its note says (§4.6): a
        // three-way merge from there. Clean, it's applied like an edit (§4.8 A); overlapping,
        // the places both changed go between markers (§4.8 B). Without that proof, both whole
        // versions go between markers: a guessed base can undo edits without a trace.
        let proven = provenBase(for: fingerprint?.sha256)
        if proven == nil, !noteWaited, fromServer, let sha = fingerprint?.sha256 {
            // A version from iCloud with no proof yet of the version both had: its note usually comes
            // a few seconds after the version (another app's change on this Mac has none, so no wait) (at 20:55 it came 5 s later, after both whole versions had gone between
            // markers, been uploaded, and been kept both, doubling the text). Wait up to 10 s for
            // it, saving nothing meanwhile (the file holds theirs; typing is in the journal).
            if waitingForNote?.sha == sha { return }
            waitingForNote = (sha, data, fingerprint, source, fromServer)
            record("merge", sha: sha, detail: "from \(source): waiting up to 10 s for its note, to merge from the version both had")
            show("‖ A NEWER VERSION FROM ANOTHER MAC · WAITING FOR ITS NOTE TO MERGE IT", for: 10)
            Task { await awaitNote(for: sha) }
            return
        }
        let clock = SyncState.clock.string(from: Date())
        let who = proven?.device ?? source.prefix(1).uppercased() + source.dropFirst()
        let mySide = ConflictText.Side(text: mine, label: "\(device) · \(clock)")
        let theirSide = ConflictText.Side(text: theirs, label: "\(who) · \(clock)")
        let sha = fingerprint?.sha256
        let conflictBy = "changed by \(proven?.device ?? source) while this Mac had \(dirty ? "unsaved edits" : "a saved version iCloud didn't have"): "
        if let proven {
            let result = Merge.threeWay(base: proven.text, mySide, theirSide)
            if result.isClean {
                applyMerge(result, sha: sha, from: proven.device)
            } else {
                writeBlocks(result.text, places: result.conflicts, merged: true, from: who)
                record("conflict", sha: sha, detail: conflictBy + "merged from the version both had, \(result.conflicts) place\(result.conflicts == 1 ? "" : "s") between markers")
            }
        } else {
            writeBlocks(ConflictText.keepBoth(mySide, theirSide), places: 1, merged: false, from: who)
            record("conflict", sha: sha, detail: conflictBy + "no version both had is known, so both whole versions, between markers")
            if let sha { unproven = Unproven(mine: mySide, theirs: theirSide, theirsSHA: sha, written: editor.textView.string, uploadedBefore: uploadedSHA) }
        }
        // Either way the file holds theirs now; with a proven base, so does the server, and the
        // result is made from it: the next merge starts there.
        baseFingerprint = fingerprint
        if proven != nil { uploadedSHA = sha }
        if let sha { incorporated.insert(sha) }
        if waitingForNote?.sha == sha { waitingForNote = nil }   // merged by another way meanwhile
    }

    /// Both versions of the places both changed, between markers in the text, where they sync
    /// and last (§4.7, §4.8 B). No dialog waits: typing goes on, and ⌘1, ⌘2, ⌘3 resolve each block.
    private func writeBlocks(_ text: String, places: Int, merged: Bool, from who: String) {
        replaceBuffer(with: text, action: "Conflict with \(who)")
        mergedAroundBlocks = merged
        show("✕ CONFLICT WITH \(who.uppercased()) · \(places) PLACE\(places == 1 ? "" : "S") · BOTH VERSIONS ARE IN THE TEXT", for: 10)
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// Blocks were written two-way, and now a note proves the base: if the text is as it was
    /// written, the three-way merge replaces them (clean, or with smaller blocks).
    private func upgradeIfProven() {
        guard let pending = unproven, let proven = provenBase(for: pending.theirsSHA, uploaded: pending.uploadedBefore) else { return }
        unproven = nil
        guard editor.textView.string == pending.written else { return }   // edited since: left as written
        var theirs = pending.theirs
        theirs.label = "\(proven.device) · \(SyncState.clock.string(from: Date()))"
        let result = Merge.threeWay(base: proven.text, pending.mine, theirs)
        replaceBuffer(with: result.text, action: "Merge from \(proven.device)")
        mergedAroundBlocks = !result.isClean
        record("merge", sha: pending.theirsSHA, detail: "its note arrived: merged from the version both had, "
               + (result.isClean ? "cleanly" : "\(result.conflicts) place\(result.conflicts == 1 ? "" : "s") between markers"))
        show(result.isClean ? "✓ MERGED FROM \(proven.device.uppercased()) AFTER ALL · ⌘Z UNDOES"
                            : "✕ CONFLICT WITH \(proven.device.uppercased()) · NARROWED TO \(result.conflicts) PLACE\(result.conflicts == 1 ? "" : "S")", for: 10)
    }

    // MARK: - iCloud conflict versions and duplicate files (§4.6 3-4, §4.8 C-D)

    /// Versions of the file that didn't come through Nib: iCloud's conflict versions (edits made
    /// while no Mac held the file) and `scratch 2.md`-style duplicates. Nothing in them is
    /// dropped: what this Mac already has is settled at once; anything else goes into the text
    /// beside this Mac's, between markers, and is settled once a save has it in the file.
    func checkOthers(reason: String) async {
        guard ready, locked == nil, !checkingOthers else { return }
        checkingOthers = true
        defer { checkingOthers = false }
        let url = self.url
        var versions = await othersQueue.run { CloudControl.conflictVersions(url) }
        #if DEBUG
        versions += TestHarness.fakeConflictVersions
        #endif
        for version in versions where !handledOthers.contains(version.sha256) {
            handleConflictVersion(version)
        }
        // Duplicates there at the first look were there before Nib: someone's own files.
        let known = "siblings:" + url.path
        let found = await othersQueue.run { Duplicates.beside(url) }
        if UserDefaults.standard.array(forKey: known) == nil { UserDefaults.standard.set(found.map(\.lastPathComponent), forKey: known) }
        let before = Set(UserDefaults.standard.stringArray(forKey: known) ?? [])
        for duplicate in found where !before.contains(duplicate.lastPathComponent) {
            guard let (data, _) = try? await othersQueue.run({ try FileAccess.read(duplicate) }) else { continue }
            handleDuplicate(duplicate, data)
        }
    }

    // MARK: - History (SY13)

    /// Bumped with every version History keeps, so Revert To and the History window follow.
    private(set) var historyChanged = 0

    private func recordHistory(_ work: @escaping @Sendable (History) -> Void) {
        let history = self.history
        Task {
            await journalQueue.run { work(history) }
            historyChanged += 1
        }
    }

    /// The note for a version waiting to be merged, for 10 s: as the note folder's watch reads
    /// it, and fresh from the server every 2 s (a fresh read evicts and downloads it: a second
    /// or more). Then the merge, from the version both had if the note proves it, else both
    /// whole versions between markers as before.
    private func awaitNote(for sha: String) async {
        let url = self.url, deadline = Date().addingTimeInterval(10)
        var lastFresh = Date.distantPast
        while Date() < deadline {
            if lastNote?.sha256 == sha { break }
            if Date().timeIntervalSince(lastFresh) >= 2 {
                lastFresh = Date()
                if let note = await io.run({ Announcement.read(for: url, fresh: true) }), note.sha256 == sha {
                    lastNote = note
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard waitingForNote?.sha == sha else { return }   // a newer version came meanwhile
        }
        guard let pending = waitingForNote, pending.sha == sha else { return }
        waitingForNote = nil
        incoming(pending.data, fingerprint: pending.fingerprint, from: pending.source, fromServer: pending.fromServer, noteWaited: true)
        if dirty { scheduleSave(after: 0) }
    }

    /// Revert To (SY13): a version from History back in the buffer as one edit (⌘Z undoes it).
    /// The version it replaces is in History too, so nothing is lost.
    func restore(_ entry: HistoryEntry) {
        guard let data = history.data(entry.sha256) else { NSSound.beep(); return }
        let text = TextFile.decode(data).text
        guard text != editor.textView.string else { return }
        let time = SyncState.clock.string(from: entry.time)
        replaceBuffer(with: text, action: "Revert to \(time)")
        show("= BACK TO THE VERSION FROM \(time) (\(entry.source.uppercased())) · ⌘Z UNDOES", for: 10)
        record("revert", sha: entry.sha256, detail: "to the version from \(time) (\(entry.source))")
    }

    /// A version this Mac has already had: identical to the buffer or the file, taken in
    /// before, or kept in History. Its text adds nothing.
    private func alreadyHave(_ text: String, sha: String) -> Bool {
        text == editor.textView.string || sha == baseFingerprint?.sha256 || incorporated.contains(sha)
            || superseded.contains(sha) || history.contains(sha)
    }

    private func handleConflictVersion(_ version: CloudControl.ConflictVersion) {
        handledOthers.insert(version.sha256)
        let theirs = TextFile.decode(version.data).text
        let who = version.savedBy ?? "another Mac"
        let known = alreadyHave(theirs, sha: version.sha256)
        let data = version.data
        recordHistory { history in try? history.record(data, parent: nil, source: "iCloud conflict version from \(who)") }
        if known {
            // Identical, or a version this Mac already has: resolved at once (§4.7).
            markResolved([version.sha256])
            record("conflict version", sha: version.sha256, detail: "from \(who): nothing this Mac doesn't have; marked resolved")
            return
        }
        // iCloud doesn't say what it was made from: both whole versions, between markers.
        let when = version.modified.map { SyncState.clock.string(from: $0) } ?? "earlier"
        let mine = ConflictText.Side(text: editor.textView.string, label: "\(device) · \(SyncState.clock.string(from: Date()))")
        writeBlocks(ConflictText.keepBoth(mine, .init(text: theirs, label: "\(who) · \(when)")), places: 1, merged: false, from: who)
        incorporated.insert(version.sha256)
        pendingResolved.insert(version.sha256)
        record("conflict", sha: version.sha256, detail: "an iCloud conflict version from \(who): both versions between markers; marked resolved once saved")
    }

    private func handleDuplicate(_ duplicate: URL, _ data: Data) {
        let name = duplicate.lastPathComponent
        let sha = Digest.sha256(data)
        guard handledOthers.insert(name + ":" + sha).inserted else { return }
        let theirs = TextFile.decode(data).text
        let identical = theirs == editor.textView.string || sha == baseFingerprint?.sha256
        let known = alreadyHave(theirs, sha: sha)
        recordHistory { history in try? history.record(data, parent: nil, source: "duplicate \(name)") }
        if known {
            trash(duplicate, sha: sha, notice: "REMOVED DUPLICATE “\(name.uppercased())” (\(identical ? "IDENTICAL" : "AN EARLIER VERSION, IN HISTORY")) · IN THE TRASH")
            return
        }
        let when = (try? duplicate.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let mine = ConflictText.Side(text: editor.textView.string, label: "\(device) · \(SyncState.clock.string(from: Date()))")
        writeBlocks(ConflictText.keepBoth(mine, .init(text: theirs, label: "\(name) · \(when.map { SyncState.clock.string(from: $0) } ?? "earlier")")),
                    places: 1, merged: false, from: name)
        incorporated.insert(sha)
        pendingTrash.append((duplicate, sha))
        record("duplicate", sha: sha, detail: "\(name): its text between markers; to the Trash once saved")
    }

    /// A save has put the conflict versions' and duplicates' text in the file: settle them.
    private func settleOthers() {
        let resolved = pendingResolved, trashing = pendingTrash
        pendingResolved = []
        pendingTrash = []
        if !resolved.isEmpty {
            markResolved(resolved)
            record("conflict version", detail: "\(resolved.count) marked resolved: their text is in the file")
        }
        for item in trashing {
            trash(item.url, sha: item.sha, notice: "MERGED “\(item.url.lastPathComponent.uppercased())” INTO THE TEXT · IT'S IN THE TRASH")
        }
    }

    private func markResolved(_ shas: Set<String>) {
        let url = self.url
        Task { await othersQueue.run { CloudControl.markResolved(url, sha256s: shas) } }
        #if DEBUG
        TestHarness.fakeConflictVersions.removeAll { shas.contains($0.sha256) }
        #endif
    }

    /// To the Trash, never deleted, and only if it's still what was read (§4.7).
    private func trash(_ duplicate: URL, sha: String, notice: String) {
        Task {
            let moved = await othersQueue.run { () -> Bool in
                guard let (data, _) = try? FileAccess.read(duplicate), Digest.sha256(data) == sha else { return false }
                return (try? FileManager.default.trashItem(at: duplicate, resultingItemURL: nil)) != nil
            }
            if moved {
                show(notice, for: 10)
                record("duplicate", sha: sha, detail: "\(duplicate.lastPathComponent) moved to the Trash")
            } else {
                record("duplicate", sha: sha, detail: "\(duplicate.lastPathComponent) changed or couldn't be moved: left where it is")
                handledOthers.remove(duplicate.lastPathComponent + ":" + sha)
            }
        }
    }

    /// The base for a three-way merge with version `sha`, when its note proves one: `sha`
    /// was made from the version this Mac last had on the server, and this Mac still has
    /// that version's text. That version is also where this Mac's edits start.
    private func provenBase(for sha: String?, uploaded: String? = nil) -> (text: String, device: String)? {
        guard let sha, let note = lastNote, note.sha256 == sha, note.device != device,
              let parent = note.parent, parent == (uploaded ?? uploadedSHA),
              let text = versions[parent] ?? history.data(parent).map({ TextFile.decode($0).text }) else { return nil }
        return (text, note.device)
    }

    /// A clean merge, applied as one edit (§4.7): one undo step, the strip says so for 10 s,
    /// then the normal save and upload.
    private func applyMerge(_ result: Merge.Result, sha: String?, from who: String) {
        replaceBuffer(with: result.text, action: "Merge from \(who)")
        let n = result.changesFromSecond
        let changes = "\(n) CHANGE\(n == 1 ? "" : "S")"
        show("✓ MERGED \(changes) FROM \(who.uppercased()) · ⌘Z UNDOES", for: 10)
        record("merge", sha: sha,
               detail: "clean: \(changes.lowercased()) from \(who) onto this Mac's edits\(result.withinLine ? ", merged within a line" : "")")
    }

    /// Nib's own change to the buffer as one edit: its own undo step (AppKit's automatic
    /// groups close with an event, and a merge doesn't come with one, so the next keystroke
    /// would otherwise join it), journaled, then the normal save and upload.
    private func replaceBuffer(with text: String, action: String) {
        saveTask?.cancel()
        let view = editor.textView
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        apply(text, undoable: true)
        view.undoManager?.setActionName(action)
        view.undoManager?.endUndoGrouping()
        view.breakUndoCoalescing()
        editCount += 1
        Task {
            await writeJournal()
            await flush(reason: "merge")
        }
    }

    /// Versions a fetch should leave alone: the ones this Mac has moved past, within 30 s of its upload.
    private func staleVersions() -> Set<String> {
        guard let lastUpload, Date().timeIntervalSince(lastUpload) < 30 else { return [] }
        return superseded
    }

    /// The version's text, kept for later merges: the last eight, never the one on the server.
    private func remember(_ text: String, sha: String?) {
        guard let sha, versions[sha] == nil else { return }
        versions[sha] = text
        versionOrder.append(sha)
        if versionOrder.count > 8, let i = versionOrder.firstIndex(where: { $0 != uploadedSHA }) {
            versions[versionOrder.remove(at: i)] = nil
        }
    }

    /// Replaces the buffer, keeping the caret near where it was. One undo step.
    private func apply(_ text: String, undoable: Bool = true) {
        let view = editor.textView
        let selection = view.selectedRange()
        applying = true
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        if undoable, view.shouldChangeText(in: full, replacementString: text) {
            view.textStorage?.replaceCharacters(in: full, with: text)
            view.didChangeText()
        } else {
            view.string = text
            editor.scheduleHighlight(after: 0)
        }
        applying = false
        let length = (text as NSString).length
        view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        updateBlocks()
    }

    // MARK: - The "latest version" note (SY14, S1b)

    /// After an upload: tell the other Macs which version the server has now.
    private func announce(_ sha: String, parent: String?) {
        let note = Announcement(sha256: sha, parent: parent, device: device, size: Int(baseFingerprint?.size ?? 0))
        let url = self.url
        Task {
            do {
                try await journalQueue.run { try note.write(for: url) }
            } catch {
                record("announce", detail: "couldn't write the note: \(CloudControl.describe(error))")
            }
        }
    }

    /// Another Mac may have announced a version this Mac doesn't have. iCloud's own state
    /// can't be trusted for a held file (S1b: stale for 26 minutes while "current"), so
    /// the note decides. No edits here: refresh. Edits: nothing to do, since the next
    /// upload is refused and the merge runs.
    func checkAnnouncement(reason: String) async {
        guard ready, locked == nil, !refreshing, !closing else { return }
        let url = self.url
        guard let note = await io.run({ Announcement.read(for: url, fresh: true) }) else { return }
        lastNote = note
        upgradeIfProven()
        guard note.device != device, !handledAnnouncements.contains(note.sha256),
              note.sha256 != baseFingerprint?.sha256, note.sha256 != uploadedSHA else { return }
        if incorporated.contains(note.sha256) || superseded.contains(note.sha256) || waitingForNote?.sha == note.sha256 {
            // Already taken in (merged, or between markers), or waited on right now: not news. (At
            // 20:55 a note put off for unsent work led to a refresh after its version was merged.)
            if waitingForNote?.sha != note.sha256 { handledAnnouncements.insert(note.sha256) }
            return
        }
        if loggedAnnouncements.insert(note.sha256).inserted {
            record("announce", sha: note.sha256, detail: "\(note.device) uploaded a version this Mac doesn't have (\(reason))")
        }
        // Unsent work here: the next upload is refused, and that merges. Not marked handled
        // until acted on, so a later check takes it up if that doesn't happen (20:02).
        guard !unsent, !saving, !uploading else { return }
        handledAnnouncements.insert(note.sha256)
        await refresh(announced: note)
    }

    /// Brings down the server's version of the held file (§4.4): hand it back taking the
    /// server's version, evict, download, hold again. About a second (S1b: 0.6-1.3 s).
    private func refresh(announced note: Announcement?) async {
        guard !closing else { return }
        if let note { lastNote = note }
        refreshing = true
        refreshes += 1
        let started = Date()
        let url = self.url
        // nib's own presenter and file watch count as users of the file, and eviction
        // refuses a file in use. The download may also bring a new inode: watch it afresh.
        NSFileCoordinator.removeFilePresenter(presenter)
        fileWatch?.cancel()
        fileWatch = nil
        defer {
            NSFileCoordinator.addFilePresenter(presenter)
            watchFile()
        }
        #if DEBUG
        if TestHarness.loseHoldBeforeRefresh {   // `refusal-lost-hold`: iCloud takes the file back meanwhile
            TestHarness.loseHoldBeforeRefresh = false
            try? await CloudControl.resume(url, .takeServerVersion)
            try? await Task.sleep(for: .seconds(2))
        }
        #endif
        do {
            let (data, fingerprint) = try await CloudControl.refetch(url, wasPaused: held)
            held = false
            // The note's Mac, if the note names this version and isn't this Mac's own (W2).
            let who = note.flatMap { $0.sha256 == fingerprint.sha256 && $0.device != device ? $0.device : nil } ?? "another Mac"
            record("refresh", size: data.count, sha: fingerprint.sha256, ms: ms(since: started),
                   detail: note == nil ? "got the server's version"
                       : fingerprint.sha256 != note?.sha256 ? "the server has another version than the one announced"
                       : note?.device == device ? "got this Mac's own version back" : "got \(who)'s version")
            await holdAgain()
            refreshing = false
            if fingerprint.sha256 != baseFingerprint?.sha256 {
                incoming(data, fingerprint: fingerprint, from: who, fromServer: true)
            } else {
                uploadedSHA = fingerprint.sha256
            }
        } catch {
            record("refresh", ms: ms(since: started), detail: "failed: \(CloudControl.describe(error))")
            if await CloudControl.status(url, within: 5)?.paused != true { held = false; await holdAgain() }
            refreshing = false
            // Whatever iCloud put in the file while the hold was down (a hand-back moments before
            // can end a hold): looked at now, with the saved work still counted as unsent.
            await diskMayHaveChanged()
        }
    }

    /// Any write, growth, attribute change, rename or delete of the file itself.
    private func watchFile() {
        fileWatch?.cancel()
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor in
                guard let self else { return }
                if event.contains(.rename) || event.contains(.delete) { self.watchFile() }   // a new inode
                await self.diskMayHaveChanged()
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        fileWatch = source
    }

    /// The `.nib` folder: a note written or replaced there changes its entries.
    private func watchNoteFolder() {
        noteWatch?.cancel()
        let descriptor = Darwin.open(Announcement.url(for: url).deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.checkAnnouncement(reason: "note folder changed") }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        noteWatch = source
    }

    private func holdAgain() async {
        do {
            try await pauseFile(waitingForUpload: false)
            held = true
        } catch {
            pausedFiles.remove(url.path)   // not paused: nothing for the next launch to hand back
            record("pause", detail: "not held yet, after a refresh: \(CloudControl.describe(error)); trying again in 2 s")
            scheduleHoldRetry()
        }
    }

    // MARK: - iCloud state and the file itself

    /// Unheld files: iCloud's own upload state, pushed through the presenter.
    func cloudAttributesChanged() {
        guard ready, !held, !dirty else { return }
        let url = self.url
        Task {
            guard let status = await CloudControl.status(url, within: 5), ready, !held, !dirty else { return }
            if status.uploading { state = .uploading(lastSaved) } else if status.uploaded { state = .synced(Date()) }
        }
    }

    func fileWasDeleted() {
        state = .problem("\(url.lastPathComponent.uppercased()) WAS MOVED OR DELETED · YOUR TEXT IS STILL HERE AND IN THE JOURNAL")
        record("problem", detail: "the file was deleted or moved away")
    }

    func fileMoved(to newURL: URL) {
        record("problem", detail: "the file moved to \(newURL.path); M1 keeps saving to the old path only after a relaunch")
        state = .problem("\(url.lastPathComponent.uppercased()) MOVED · QUIT AND REOPEN NIB")
    }

    // MARK: - Activation, network, quitting

    /// nib came forward: check the server now, then every 30 s while it stays in front.
    func becameActive() {
        guard !untitled else { return }   // on this Mac only: nothing to check
        Task {
            if held { await diskMayHaveChanged() }   // another app on this Mac may have written it
            await checkAnnouncement(reason: "activated")
            await fetchLatest(reason: "activated")
            await checkOthers(reason: "activated")
        }
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAnnouncement(reason: "every 30 s")
                await self?.fetchLatest(reason: "every 30 s")
                await self?.checkOthers(reason: "every 30 s")
            }
        }
    }

    func resignedActive() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        Task { await flush(reason: "app switch") }
    }

    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.online != up else { return }
                self.online = up
                if up {
                    await self.upload(now: true)
                    await self.checkAnnouncement(reason: "network back")
                    await self.fetchLatest(reason: "network back")
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "nib.network"))
    }

    /// Quitting: save, upload, hand the file back to iCloud (§4.3; a pause outlives the app).
    func close() async {
        closing = true
        holdRetry?.cancel()
        for _ in 0..<200 where pausing { try? await Task.sleep(for: .milliseconds(100)) }   // a hold in flight (≤ 20 s)
        let started = Date()
        record("quit", detail: "closing")
        editor.saveSelection(for: url)
        await flush(reason: "quit")
        for _ in 0..<50 where uploading { try? await Task.sleep(for: .milliseconds(100)) }
        NSFileCoordinator.removeFilePresenter(presenter)
        NSFileCoordinator.removeFilePresenter(notePresenter)
        fileWatch?.cancel()
        noteWatch?.cancel()
        guard held else { return }
        let clean = !dirty && uploadedSHA != nil && uploadedSHA == baseFingerprint?.sha256
        record("quit", ms: ms(since: started), detail: clean ? "everything uploaded; resuming iCloud sync" : "unsent edits; resuming iCloud sync")
        if !clean { await writeJournal() }   // the next launch compares it with the file (§4.8 G)
        var handedBack = false
        for attempt in 1...2 {
            do {
                try await resumeFile(clean ? .takeServerVersion : .uploadFailingOnConflict)
                handedBack = true
                break
            } catch where CloudControl.isConflict(error) {
                // A newer version on the server and unsent edits here: take the server's; the
                // journal (and iCloud's alternate version) keep ours for the next launch.
                record("resume", detail: "upload refused at quit, taking the server's version; this Mac's text is in the journal: \(CloudControl.describe(error))")
                handedBack = (try? await resumeFile(.takeServerVersion)) != nil
                break
            } catch where CloudControl.isUnsupported(error) {
                // "Not supported": it isn't paused (any more), so there's nothing to hand back.
                handedBack = true
                break
            } catch {
                // Passing (iCloud's helper not answering, say): once more, then leave it paused and
                // listed, for the next launch to hand back. Never the server's version for this.
                if attempt == 1 { try? await Task.sleep(for: .seconds(1)); continue }
                record("resume", detail: "handing it back failed twice (\(CloudControl.describe(error))): left paused, for the next launch to hand back")
            }
        }
        guard handedBack else { return }
        held = false
        pausedFiles.remove(url.path)
        record("resume", ms: ms(since: started))
    }

    /// At launch: any file still paused from an earlier session that isn't this one goes back to iCloud (§4.9, 14a).
    static func settlePausedFiles(except keep: URL) async {
        let list = PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json"))
        for path in list.all() where path != keep.path {
            let url = URL(fileURLWithPath: path)
            do {
                try await CloudControl.resume(url, .uploadFailingOnConflict)
            } catch where CloudControl.isConflict(error) {
                // The server is newer: take its version; local changes become an alternate version.
                guard (try? await CloudControl.resume(url, .takeServerVersion)) != nil else { continue }
            } catch where CloudControl.isUnsupported(error) {
                // Not paused after all: nothing to hand back.
            } catch {
                continue   // passing: still paused, still listed; the next launch tries again
            }
            list.remove(path)
        }
    }

    // MARK: - Helpers

    func show(_ text: String, for seconds: Double) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func record(_ event: String, size: Int? = nil, sha: String? = nil, ms: Int? = nil, detail: String? = nil) {
        guard !untitled else { return }   // the Sync Log is about syncing; untitled buffers never do
        log.append(SyncEvent(event, path: url.path, device: device, size: size, sha256: sha, ms: ms, detail: detail))
    }

    private func ms(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }

    private func short(_ error: Error) -> String {
        (error as NSError).localizedDescription.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    #if DEBUG
    /// For the test harness.
    var debugSnapshot: (dirty: Bool, uploadedSHA: String?, baseSHA: String?, held: Bool) {
        (dirty, uploadedSHA, baseFingerprint?.sha256, held)
    }
    #endif
}

// MARK: Indentation and Go to Line (ED6)

extension Document {
    /// For a file that doesn't show its own: Settings › Editor's (or Sublime's, imported).
    static var defaultIndentation: Indentation {
        let defaults = UserDefaults.standard
        let width = max(1, min(16, defaults.object(forKey: "editorTabSize") as? Int ?? 4))
        return defaults.bool(forKey: "editorSpaces") ? .spaces(width) : .tabs(width: width)
    }

    var indentationLabel: String {
        switch indentation {
        case .tabs: "TABS"
        case .spaces(let n): "\(n) SPACE\(n == 1 ? "" : "S")"
        }
    }

    /// ⌘P, ⌘K, ⇧⌘P: the palette over this window. The commands are listed now, as the menus
    /// are with this window in front, before the sheet takes the focus.
    func showPalette(_ kind: PaletteSession.Kind) {
        guard merge == nil, palette == nil else { NSSound.beep(); return }
        palette = PaletteSession(kind, for: self)
    }

    /// The palette has gone: what was chosen in it, if anything.
    func finishPalette() {
        shownPalette?.finish()
        shownPalette = nil
    }

    /// Go to Line: "12", or "12:5" for a column too. False if it isn't a line number.
    @discardableResult
    func goToLine(_ answer: String) -> Bool {
        goingToLine = false
        let parts = answer.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        let view = editor.textView
        view.window?.makeFirstResponder(view)
        guard let line = parts.first, line > 0 else { return false }
        let text = view.string as NSString
        let start = LineEdits.start(ofLine: line, in: view.string)
        let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
        let contentEnd = NSMaxRange(lineRange) - (NSMaxRange(lineRange) > start && text.character(at: NSMaxRange(lineRange) - 1) == 0x0A ? 1 : 0)
        let column = parts.count > 1 ? max(1, parts[1]) : 1
        let location = min(start + column - 1, contentEnd)
        view.setSelectedRange(NSRange(location: location, length: 0))
        view.scrollRangeToVisible(NSRange(location: location, length: 0))
        return true
    }
}

// MARK: Syntax (HL1)

extension Document {
    /// Picks the file's syntax from the strip or View › Syntax, kept for the file; nil is
    /// Automatic. Only the colors change: it isn't an edit.
    func pickSyntax(_ pick: SyntaxPick?) {
        pickedSyntax = pick
        UserDefaults.standard.set(pick?.stored, forKey: "syntax:" + url.path)
        applySyntax()
    }

    /// The pick if there is one, else what the file's name and first line say.
    func applySyntax() {
        let firstLine = editor.textView.string.prefix(256).components(separatedBy: "\n").first
        let detected = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: firstLine)
        detectedSyntax = detected?.language
        let syntax: (language: SyntaxLanguage, root: String)?
        switch pickedSyntax {
        case nil: syntax = detected
        case .plain: syntax = nil
        case .language(let language):
            // Shell keeps zsh's scopes when the file's name or shebang says zsh.
            syntax = detected?.language == language ? detected : language.rootScope.map { (language, $0) }
        }
        syntaxName = syntax?.language.name.uppercased() ?? "PLAIN TEXT"
        editor.syntax = syntax
    }
}

/// A syntax picked by hand (HL1): plain text or one of the languages.
enum SyntaxPick: Hashable {
    case plain
    case language(SyntaxLanguage)

    /// In the menus' order.
    static let all: [SyntaxPick] = [.plain] + [SyntaxLanguage.html, .css, .javascript, .json, .markdown, .shell].map { .language($0) }

    var name: String {
        switch self {
        case .plain: "Plain Text"
        case .language(let language): language.name
        }
    }

    var stored: String {
        switch self {
        case .plain: "plain"
        case .language(let language): language.rawValue
        }
    }

    init?(stored: String) {
        if stored == "plain" { self = .plain; return }
        guard let language = SyntaxLanguage(rawValue: stored), language != .markdownInline else { return nil }
        self = .language(language)
    }
}

/// A serial queue for blocking file work, awaitable from the main actor.
final class IOQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Where the scratch file is (PRD §4.2): Nib's own folder in iCloud Drive, "Nib", an app
/// container like other apps' folders, with the sync notes hidden inside it. And the M1
/// safety rule (§8): until M1 has passed on both Macs, nib opens only test files, in
/// iCloud Drive/Nib/Test/ (or, in ad-hoc builds that can't carry the iCloud entitlement,
/// iCloud Drive/nib-spike/).
enum ScratchLocation {
    static let containerID = "iCloud.com.banastas.nib"
    /// iCloud Drive/Nib/ on disk.
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/iCloud~com~banastas~nib/Documents")
    static let testFolder = folder.appendingPathComponent("Test")
    static let unsignedTestFolder = NibPaths.iCloudDrive.appendingPathComponent("nib-spike")

    /// Signed with the iCloud container (a team-signed build), or not (ad-hoc).
    static let hasContainer: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-container-identifiers" as CFString, nil) != nil
    }()

    static var url: URL {
        if let path = UserDefaults.standard.string(forKey: "scratchPath") { return URL(fileURLWithPath: path) }
        return (hasContainer ? testFolder : unsignedTestFolder).appendingPathComponent("scratch-test.md")
    }

    static func inContainer(_ url: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(folder.path + "/") }

    /// Where a file is, as Finder would name its folder: "iCloud Drive › Nib › Test" (Nib's own
    /// folder), "iCloud Drive › nib-spike", or the path from ~.
    static func place(of url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        for (root, name) in [(Self.folder.path, "iCloud Drive › Nib"), (NibPaths.iCloudDrive.path, "iCloud Drive")]
        where folder == root || folder.hasPrefix(root + "/") {
            let rest = folder.dropFirst(root.count).split(separator: "/")
            return ([name] + rest.map(String.init)).joined(separator: " › ")
        }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    static func refusal(for url: URL) -> String? {
        if UserDefaults.standard.bool(forKey: "allowLiveScratch") { return nil }
        if Untitled.contains(url) { return nil }   // Nib's own, on this Mac only (ED3)
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(testFolder.path + "/") || path.hasPrefix(unsignedTestFolder.path + "/") else {
            return "NIB OPENS ONLY TEST FILES (ICLOUD DRIVE › NIB › TEST) UNTIL M1 HAS PASSED (PRD §8)"
        }
        return nil
    }
}
