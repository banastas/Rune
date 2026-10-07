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
    private(set) var state: SyncState = .opening {
        didSet {
            endAlerts(for: state)
            // A problem is said as it begins, where its strip can be seen; where it can't, it's
            // notified (VoiceOver heard nothing of either while Nib was in front: the QA review's F37).
            if case .problem(let why) = state, oldValue != state, Notifier.inFront(url) { Announce.hud("✕ " + why, urgent: true) }
            // The disk has room again once a save lands (typing sets .editing, full disk or not).
            switch state {
            case .saved, .savedHere, .local, .synced: if fullVolume != nil { fullVolume = nil; trashOffer = nil }
            default: break
            }
            watchStall()
        }
    }
    /// Saved here a minute or more with the network up and iCloud not uploading it: how long, in
    /// minutes, said after the strip's "= SAVED LOCALLY" (§4.5 W4; the QA review's F42: an unheld
    /// file sat there however long iCloud waited, saying nothing).
    private(set) var stalledMinutes: Int?
    @ObservationIgnored private var stallTask: Task<Void, Never>?

    private func watchStall() {
        guard case .saved = state else {
            stallTask?.cancel()
            stallTask = nil
            if stalledMinutes != nil { stalledMinutes = nil }
            return
        }
        guard stallTask == nil else { return }
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.stallCheckEvery))
                guard let self, !Task.isCancelled, case .saved(let since) = self.state else { return }
                let waited = Date().timeIntervalSince(since)
                let shown = self.online && waited >= Self.stallAfter ? max(1, Int(waited / 60)) : nil
                if self.stalledMinutes != shown { self.stalledMinutes = shown }
            }
        }
    }

    /// Since when this version's upload has been waiting for no reason of its own: its save, or
    /// later when typing's pause is to be waited out first (UploadSchedule; after a long idle that
    /// due time is long past, and the first save uploads at once). The menu bar marches only once
    /// one is 3 s past it, not through the pause it waits for by design (F43). Nil when nothing waits.
    var uploadPendingSince: Date? {
        switch state {
        case .saved(let time), .uploading(let time): max(uploads.due, time)
        default: nil
        }
    }

    /// A minute (§4.5), and how often it's looked at; the `menubar` scenario makes them short.
    static var stallAfter: Double = 60
    static var stallCheckEvery: Double = 15
    /// While this Mac's disk is full (§4.9, 13): the Trash that would give space back, as the
    /// strip offers it, or nil (none, or empty).
    private(set) var trashOffer: TrashOffer?
    /// Where the disk filled up: the file, the journal or the Recovery folder.
    @ObservationIgnored private var fullVolume: URL?

    struct TrashOffer: Equatable {
        /// What it would free; nil when Nib can't look inside (the Mac's own Trash, without Full
        /// Disk Access), and Finder is asked on the click.
        var bytes: Int64?
        var label: String { bytes.map { "EMPTY TRASH · " + $0.formatted(.byteCount(style: .file)).uppercased() } ?? "EMPTY TRASH" }
        var spoken: String { bytes.map { "Empty the Trash, " + $0.formatted(.byteCount(style: .file)) } ?? "Empty the Trash" }
    }
    private(set) var format = FileFormat.standard
    /// A line that shows in the strip for a while ("▼ UPDATED FROM …", "RECOVERED …").
    private(set) var notice: String?
    /// For the strip: "MARKDOWN", "JAVASCRIPT", "PLAIN TEXT" (HL1).
    private(set) var syntaxName = "PLAIN TEXT"
    /// Over 5,000,000 characters (ED9): no highlighting, and the strip says so with the size.
    private(set) var highlightingOff = false
    /// The file's size in bytes, as last read or saved (ED9's strip).
    private(set) var fileBytes = 0
    /// Over 5 MB, History keeps the version opened and the one closed with, none of the saves between:
    /// at 42 MB a save a pause was gigabytes a day (ED9). Set when a save went unrecorded.
    @ObservationIgnored private var historyBehind = false
    /// The syntax picked from the strip or View › Syntax, which the file keeps; nil follows
    /// the file's name and first line, which say `detectedSyntax` (nil: plain text).
    private(set) var pickedSyntax: SyntaxPick?
    /// How the file indents (ED6), found on open; for the strip ("TABS", "2 SPACES").
    private(set) var indentation: Indentation = .tabs(width: 4)
    /// The strip's line slot is a field for Go to Line (⌃G).
    var goingToLine = false
    /// The sync HUD open over the text (§5.3): the strip's sync state clicked, or ⇧⌘Y.
    var syncDetailsShown = false
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
    /// Asked for, its list on the way (`showPalette`).
    @ObservationIgnored var paletteComing = false
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
    /// The first run (AP5) with no scratch file yet: none is made until the welcome window says
    /// where, or two Macs each making one on their first run leave a "scratch 2.md" (§4.6 C).
    private(set) var awaitingFirstRun = false
    private(set) var cursor = (line: 1, column: 1)
    /// How many carets (ED8): the strip says so past one; line and column are the primary's.
    var caretCount = 1

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
    /// For reading the other Macs' notes. A fresh read evicts the note and downloads it, which
    /// can take seconds; on the document's own queue, saves waited behind it (3.8 s of a save
    /// at 18:36 on 2026-09-29 was waiting, 34 ms was writing).
    @ObservationIgnored private let notesQueue = IOQueue(label: "nib.notes")

    /// The version the buffer came from, or was last saved as.
    @ObservationIgnored private var baseFingerprint: Fingerprint? {
        didSet {
            if let sha = baseFingerprint?.sha256, sha != oldValue?.sha256 {
                ReceiptBook.shared.loaded(url, sha: sha)   // this Mac's receipt (SY14)
                updateOtherMacs()
            }
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
    /// When the last upload began: one made after it, with no save between, would send it again.
    @ObservationIgnored private var uploadBegan: Date?
    /// When typing's saves go up to iCloud (§4.3 step 7).
    @ObservationIgnored private var uploads: UploadSchedule
    @ObservationIgnored private var uploadedSHA: String?
    @ObservationIgnored private var uploadBackoff: TimeInterval = 10
    @ObservationIgnored private var lastSaved = Date()
    @ObservationIgnored private var online = true
    @ObservationIgnored private var watchingNetwork = false
    /// Not on this Mac (evicted) and offline, or iCloud slow to bring it: the buffer is the last
    /// version Nib saw, typing allowed, and nothing is read from or written to the file until it's
    /// here (§4.8 F, §4.9 7).
    @ObservationIgnored private(set) var awaitingDownload = false
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
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
    /// The other Macs' versions of this file, from their receipts (SY14, §4.5).
    private(set) var otherMacs: [OtherMac] = []
    struct OtherMac: Equatable {
        var device: String
        var loaded: DeviceReceipts.Loaded
        var delivery: Delivery

        // One wording for the HUD, the menu bar panel, the strip and its tooltip: each said it its
        // own way ("OLDER · 21:06", "…HAS 21:06:27'S", "…it has one from 21:06:27…": the QA
        // review's F41). Times by that Mac's clock, with the day when it isn't today.
        var time: String { SyncState.stamp(loaded.time) }

        /// The HUD's MACS row: "✓ SINCE 10:42:31", "▼ NEWER · 10:42:31", "NOT YET · 10:40:12".
        var short: String {
            switch delivery {
            case .same: "✓ SINCE \(time)"
            case .newer: "▼ NEWER · \(time)"
            case .earlier: "NOT YET · \(time)"
            }
        }

        /// The panel's and the strip's line: "✓ ON AIR · SINCE 10:42:31", "▼ NEWER ON AIR ·
        /// 10:42:31 · NOT HERE YET", "AIR HASN'T GOT THIS VERSION YET · IT HAS 10:40:12'S".
        var line: String {
            let name = device.uppercased()
            return switch delivery {
            case .same: "✓ ON \(name) · SINCE \(time)"
            case .newer: "▼ NEWER ON \(name) · \(time) · NOT HERE YET"
            case .earlier: "\(name) HASN'T GOT THIS VERSION YET · IT HAS \(time)'S"
            }
        }

        /// The tooltip's and VoiceOver's sentence.
        var sentence: String {
            let when = SyncState.spokenStamp(loaded.time)
            return switch delivery {
            case .same: "\(device) has this version, since \(when) by its clock"
            case .newer: "\(device) has a newer version, from \(when) by its clock, that isn't here yet"
            case .earlier: "\(device) hasn't got this version yet: it has the one from \(when) by its clock"
            }
        }
    }
    /// Versions this Mac saved, and when: a receipt for one says how long it took to get there.
    @ObservationIgnored private var madeHere: [String: Date] = [:]
    @ObservationIgnored private var loggedReceipts: Set<String> = []
    @ObservationIgnored private var handledAnnouncements: Set<String> = []
    @ObservationIgnored private var loggedAnnouncements: Set<String> = []
    /// The last note read: which version is on the server, and what it was made from.
    @ObservationIgnored private var lastNote: Announcement? { didSet { if let lastNote, lastNote.device != device { otherMac = lastNote } } }
    /// The latest note from another Mac: the menu bar panel's "other Macs" line (§5.7).
    private(set) var otherMac: Announcement?
    /// When this Mac's last upload was taken, and when the version in the file was saved (the
    /// panel's and the HUD's times): its modification time at open, nil when there's no file
    /// here yet. Both were the time it opened, as if saved and uploaded then (the QA review's F13).
    private(set) var uploadedAt: Date?
    private(set) var savedAt: Date?
    /// iCloud had the file's version when it opened: uploaded, by this Mac or another, before.
    private(set) var uploadedBeforeOpening = false
    /// The version the buffer comes from, or was last saved as (the sync HUD's SHA256).
    var versionSHA: String? { baseFingerprint?.sha256 }

    func toggleSyncDetails() { syncDetailsShown.toggle() }

    /// A source as a marker's label: capitalised, but "iCloud" as Apple writes it (F9).
    static func label(_ source: String) -> String {
        source.hasPrefix("iCloud") ? source : source.prefix(1).uppercased() + source.dropFirst()
    }

    /// In iCloud Drive, where receipts and notes go: a file outside it has nothing to sync.
    var inICloud: Bool { ReceiptBook.applies(to: url) }

    static let emptyScratchLine = "Paste or type. Saved as you go, on every Mac."

    /// Saved: waiting for iCloud in iCloud Drive, done outside it (F6).
    private func savedState(_ time: Date) -> SyncState { inICloud ? .saved(time) : .savedHere(time) }
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
    /// Closed: nothing reads or writes its file any more. A History window left open after its
    /// file's tab closed kept the document, and Restore then saved into the file with no window
    /// and no hold (the QA review's F2, 2026-10-07).
    private(set) var closed = false
    /// The SHA-256 of the empty file opening made, for a path with no file (`nib new.md`).
    @ObservationIgnored private var madeEmpty: String?
    @ObservationIgnored private var noteWatch: DispatchSourceFileSystemObject?
    /// A check for another Mac's note under way, and one asked for meanwhile (`checkAnnouncement`).
    @ObservationIgnored private var checkingNote = false
    @ObservationIgnored private var noteAgain: (reason: String, fresh: Bool)?

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
        #if DEBUG
        AppDelegate.mark("a document made: \(url.lastPathComponent)")
        #endif
        self.url = url
        untitled = Untitled.contains(url)
        let defaults = NibDefaults.store
        schedule = SaveSchedule(idle: defaults.object(forKey: "NibSaveIdle") as? TimeInterval ?? 1,
                                maxWait: defaults.object(forKey: "NibSaveMax") as? TimeInterval ?? 5)
        uploads = UploadSchedule(pause: defaults.object(forKey: "NibUploadPause") as? TimeInterval ?? 3,
                                 interval: defaults.object(forKey: "NibUploadEvery") as? TimeInterval ?? 20)
        presenter = Presenter(url: url)
        notePresenter = NotePresenter(note: Announcement.url(for: url))
        history = History(root: NibPaths.support.appendingPathComponent("History"), path: url.path)
        editor = Editor()
        presenter.document = self
        #if DEBUG
        AppDelegate.mark("its editor made")
        #endif
        notePresenter.document = self
        editor.document = self
    }

    // MARK: - Opening

    #if DEBUG
    /// The open's steps and their times, for the `bigopen` and `perf` scenarios.
    @ObservationIgnored private(set) var openSteps: [String] = []
    @ObservationIgnored let made = Date()
    #else
    #endif

    /// Not opened yet: the welcome window will say which file, or make it (AP5).
    func awaitFirstRun() {
        awaitingFirstRun = true
        // Said as a way back: the welcome window may be closed (the QA review's F21).
        state = .waiting("NO SCRATCH FILE YET · HELP › WELCOME TO NIB SETS ONE UP")
        editor.textView.isEditable = false
    }

    func open() async {
        #if DEBUG
        if self === Documents.scratch { AppDelegate.mark("the open starting") }
        #endif
        if let reason = ScratchLocation.refusal(for: url) {
            locked = reason
            state = .problem(reason)
            editor.textView.isEditable = false
            return
        }
        if awaitingFirstRun {
            awaitingFirstRun = false
            editor.textView.isEditable = true
            state = .opening
        }
        let url = self.url
        let presenter = self.presenter
        // How long each step took, for the Sync Log's open line (§6.5's launch to an editable window).
        var steps: [String] = []
        var stepStart = Date()
        #if DEBUG
        steps.append("asked to open, to opening \(Int(stepStart.timeIntervalSince(made) * 1000)) ms")
        #endif
        func step(_ name: String) {
            steps.append("\(name) \(Int(Date().timeIntervalSince(stepStart) * 1000)) ms")
            stepStart = Date()
        }
        if ScratchLocation.inContainer(url) {
            // Sets up nib's iCloud folder on first use; false when iCloud Drive is off. iCloud may not
            // answer at all: then, with the file already here, open it anyway.
            let container = await CloudControl.containerAvailable(ScratchLocation.containerID, within: 10)
            step("iCloud's folder")
            if container == nil { record("open", detail: "iCloud didn't answer about Nib's folder in 10 s: opening the file anyway") }
            guard container != false, container == true || FileManager.default.fileExists(atPath: url.path) else {
                state = .problem("NIB'S ICLOUD FOLDER ISN'T AVAILABLE · IS ICLOUD DRIVE ON? · NOTHING WAS OPENED")
                record("problem", detail: "url(forUbiquityContainerIdentifier:) returned nil")
                return
            }
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                if case .written(let fingerprint, _) = try await io.run({ try FileAccess.write(Data(), to: url, base: nil, presenter: presenter) }) {
                    baseFingerprint = fingerprint
                    if self !== Documents.scratch { madeEmpty = fingerprint.sha256 }
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
        stepStart = Date()
        let answered = await CloudControl.status(url, within: 10)
        step("iCloud's status")
        if answered == nil { record("open", detail: "iCloud didn't say how the file stands in 10 s: opening it anyway, and holding it once iCloud answers") }
        let status = answered ?? CloudControl.Status()
        var shadow: (entry: HistoryEntry, data: Data)?
        if status.downloadStatus == "notDownloaded" {
            // Evicted (§4.9, 7). Never a coordinated read that waits for the download: offline, it
            // waits for good. Ask for it, and open it once it's here; when it doesn't come (offline,
            // or iCloud slow), the copy Nib saw last, typing allowed (§4.8 F); with no copy, wait.
            state = .notDownloaded
            watchNetwork()
            if !(await downloaded(within: 20)) {
                if let copy = await shadowCopy() {
                    shadow = copy
                } else {
                    state = .waiting(offlineNow ? "NOT ON THIS MAC · OFFLINE · IT OPENS WHEN ICLOUD RETURNS" : "NOT ON THIS MAC · WAITING FOR ICLOUD TO BRING IT")
                    editor.textView.isEditable = false
                    while !closing, !(await downloaded(within: 30)) {}
                    guard !closing else { return }
                    editor.textView.isEditable = true
                    state = .notDownloaded
                }
            }
            step("downloading")
        }
        var text = ""
        if let shadow {
            let decoded = TextFile.decode(shadow.data)
            text = decoded.text
            format = decoded.format
            fileBytes = shadow.data.count
            baseFingerprint = Fingerprint(size: Int64(shadow.data.count), modified: 0, fileID: 0, sha256: shadow.entry.sha256)
            uploadedSHA = shadow.entry.sha256   // a version this Mac had: a note naming it as the parent proves a merge's base (§4.6)
            remember(text, sha: shadow.entry.sha256)
            step("the copy Nib saw last")
        } else {
            do {
                let (data, fingerprint) = try await io.run { try FileAccess.read(url, presenter: presenter) }
                step("reading")
                let decoded = TextFile.decode(data)
                step("decoding")
                text = decoded.text
                format = decoded.format
                fileBytes = data.count
                baseFingerprint = fingerprint
                savedAt = Date(timeIntervalSince1970: fingerprint.modified)
                remember(text, sha: fingerprint.sha256)
                recordHistory { history in try? history.record(data, parent: nil, source: "opened") }
            } catch {
                state = .problem("COULDN'T READ \(url.lastPathComponent.uppercased()) · \(short(error))")
                record("problem", detail: CloudControl.describe(error))
                return
            }
        }
        applying = true
        stepStart = Date()
        // The empty scratch file says what it's for (§5.1, W6; F56); outside iCloud Drive it isn't
        // on every Mac.
        if self === Documents.scratch {
            editor.textView.placeholder = inICloud ? Self.emptyScratchLine : "Paste or type. Saved as you go."
        }
        editor.textView.string = text
        step("into the view")
        applying = false
        highlightingOff = (text as NSString).length > Editor.highlightLimit
        editor.restoreSelection(for: url)
        step("the caret")
        updateBlocks()
        step("conflict blocks")
        if !untitled {
            NSFileCoordinator.addFilePresenter(presenter)
            try? FileManager.default.createDirectory(at: Announcement.url(for: url).deletingLastPathComponent(), withIntermediateDirectories: true)
            NSFileCoordinator.addFilePresenter(notePresenter)
            watchFile()
            watchNoteFolder()
        }
        step("watching")
        record("open", size: text.utf8.count, sha: baseFingerprint?.sha256,
               detail: (shadow.map { "not on this Mac and \(offlineNow ? "offline" : "iCloud slow to bring it"): the copy Nib saw last (\($0.entry.source), \(SyncState.clock.string(from: $0.entry.time))), typing to merge when the file comes · " } ?? "") + steps.joined(separator: " · "))
        #if DEBUG
        if self === Documents.scratch { AppDelegate.mark("text shown") }
        #endif
        stepStart = Date()
        recoverFromJournal(fileText: text)
        step("the journal")
        #if DEBUG
        if self === Documents.scratch { AppDelegate.mark("journal looked at") }
        #endif
        pickedSyntax = NibDefaults.store.string(forKey: "syntax:" + url.path).flatMap(SyntaxPick.init(stored:))
        applySyntax()
        step("the syntax")
        #if DEBUG
        if self === Documents.scratch { AppDelegate.mark("syntax applied") }
        #endif
        indentation = Indentation.detect(in: text, fallback: Self.defaultIndentation)   // the text as read (the view's would be a copy)
        editor.indentation = indentation
        step("indentation")
        #if DEBUG
        openSteps = steps
        #endif
        if let shadow {
            state = .offline(shadow.entry.time, slow: !offlineNow)
            awaitingDownload = true
            editor.textView.alphaValue = 0.75   // slightly dimmed (§4.8 F)
        } else {
            // The version's own time, not the time it opened (F13).
            let version = savedAt ?? Date()
            uploadedBeforeOpening = !untitled && status.uploaded
            state = untitled ? .local(version) : status.uploaded ? .synced(version) : savedState(version)
        }
        ready = true
        Task { await reloadHistory() }   // for Revert To and the History window (F57)
        #if DEBUG
        if self === Documents.scratch { AppDelegate.launchMoments.text = AppDelegate.launchMoments.text ?? Date() }
        #endif
        ReceiptBook.shared.watch(url)   // the other Macs' receipts (SY14)
        updateOtherMacs()
        if untitled {
            // Nothing to hold, fetch or announce: it's on this Mac only.
            thinHistory()
            if dirty { scheduleSave() }
            return
        }
        watchNetwork()
        if shadow != nil { awaitDownload(); return }   // the rest once the file is here
        await holdAndCatchUp(answered == nil ? nil : status)
    }

    /// An open file held (§4.3; with no answer from iCloud, held by the background retry once it
    /// answers) and brought up to date: an upload a crash may have left, then what other Macs did.
    private func holdAndCatchUp(_ status: CloudControl.Status?) async {
        if let status { await hold(status) } else { scheduleHoldRetry() }
        if held, let status {
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
        thinHistory()
        if dirty { scheduleSave() }
    }

    // MARK: - Not on this Mac (§4.8 F, §4.9 7)

    /// This Mac offline, as the network monitor last said (or as the `evicted` scenario says).
    private var offlineNow: Bool {
        #if DEBUG
        if TestHarness.offline { return true }
        #endif
        return !online
    }

    /// Asks iCloud for the file and waits for it: true once it's on this Mac; false when `seconds`
    /// pass, this Mac is offline (after a moment for the network monitor to say), or it closes.
    private func downloaded(within seconds: Double) async -> Bool {
        let url = self.url, io = self.io, started = Date()
        var asked = false
        while !closing {
            let waited = Date().timeIntervalSince(started)
            #if DEBUG
            if TestHarness.slowDownload {   // the `evicted` scenario: online, iCloud slow (F15)
                if waited >= min(seconds, 2) { return false }
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            #endif
            if offlineNow {
                if waited > 1.5 { return false }
            } else if !asked {
                asked = true
                _ = try? await CloudControl.within(10) { try await io.run { try FileManager.default.startDownloadingUbiquitousItem(at: url) } }
            }
            if !offlineNow, let status = await CloudControl.status(url, within: 5), status.downloadStatus != "notDownloaded" { return true }
            if waited >= seconds { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The last version Nib saw of this file: History's newest (§6.4's shadow copy).
    private func shadowCopy() async -> (entry: HistoryEntry, data: Data)? {
        let history = self.history
        return await journalQueue.run {
            guard let entry = history.entries().max(by: { $0.time < $1.time }), let data = history.data(entry.sha256) else { return nil }
            return (entry, data)
        }
    }

    /// After opening from the copy: asks for the file whenever this Mac is online, until it's here.
    private func awaitDownload() {
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.closing {
                if await self.downloaded(within: 30) {
                    await self.downloadArrived()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The file is on this Mac again: taken in over the copy as any version from iCloud is (§4.4).
    /// The same as the copy, and the typing is saved over it; another, merged with the typing
    /// (§4.7), or the buffer replaced when nothing was typed. Then held, as any open file.
    private func downloadArrived() async {
        let url = self.url, presenter = self.presenter, io = self.io
        guard let (data, fingerprint) = try? await CloudControl.within(30, { try await io.run { try FileAccess.read(url, presenter: presenter) } }) else {
            awaitDownload()   // not readable after all: ask again
            return
        }
        let status = await CloudControl.status(url, within: 10)
        let note = await notesQueue.run { Announcement.read(for: url) }
        if let note { lastNote = note }
        let who = note.flatMap { $0.sha256 == fingerprint.sha256 && $0.device != device ? $0.device : nil } ?? "another Mac"
        record("reload", sha: fingerprint.sha256, detail: "the file is on this Mac again: taken in over the copy shown while it wasn't")
        state = dirty ? .editing : status?.uploaded == true ? .synced(Date()) : savedState(Date())
        // Still awaiting it until it's taken in: cleared before the waits above, a disk check
        // took it in first, with no note, and put both whole versions between markers (the suite).
        incoming(data, fingerprint: fingerprint, from: who, fromServer: true)
        awaitingDownload = false
        editor.textView.alphaValue = 1
        await holdAndCatchUp(status)
    }

    /// A journal newer than the file means the last session ended before it saved (§4.8 G).
    private func recoverFromJournal(fileText: String) {
        guard let entry = journal.read(path: url.path) else { journal.remove(path: url.path); return }   // a clean one, left by a quit
        guard entry.text != fileText else { journal.remove(path: url.path); return }
        if entry.baseSHA256 == baseFingerprint?.sha256 {
            // The file hasn't changed since those edits began: they simply win, the caret where
            // it was left (setting the text put it at the end).
            let selection = editor.textView.selectedRange()
            applying = true
            editor.textView.string = entry.text
            applying = false
            editor.textView.setSelectedRange(NSRange(location: min(selection.location, (entry.text as NSString).length), length: 0))
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
        if let still = error as? StillUploading { return "iCloud is still uploading it after \(Int(still.seconds.rounded())) s" }
        return (error as? CloudControl.ControlError) == .unsupported
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
    /// 30 KB file took 3 s), or it stops answering; closing ends the wait, and the hold. Still
    /// uploading then, it isn't paused (`StillUploading`), as that's the crash: the hold is tried
    /// again later, the file unheld meanwhile. A file back with iCloud Drive (the `icloudoff`
    /// scenario, 2026-10-02) was still "uploading" after the 15 s, as iCloud said, and the pause
    /// made then went unanswered for its 20 s. Not uploading but not uploaded either, it's paused
    /// once the 15 s are up, as before (whether that's safe with no network isn't known, §8 M2).
    private func waitForUpload(limit: Double = 15) async throws -> Double {
        let url = self.url, started = Date()
        var uploading = false   // as iCloud last said
        while Date().timeIntervalSince(started) < limit {
            guard !closing else { throw CancellationError() }
            uploading = false
            guard let status = await CloudControl.status(url, within: 5) else { break }
            // A paused file doesn't upload; one iCloud doesn't sync has nothing to wait for.
            guard status.paused != true, status.ubiquitous, status.uploading || !status.uploaded else { break }
            uploading = status.uploading
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !closing else { throw CancellationError() }
        let waited = Date().timeIntervalSince(started)
        #if DEBUG
        if TestHarness.stillUploading > 0 {
            TestHarness.stillUploading -= 1
            if waited < limit { try? await Task.sleep(for: .seconds(limit - waited)) }
            throw StillUploading(seconds: Date().timeIntervalSince(started))
        }
        #endif
        if uploading { throw StillUploading(seconds: waited) }
        return waited
    }

    /// The wait for iCloud's upload ran out with iCloud still uploading the file: not paused.
    struct StillUploading: Error {
        var seconds: Double
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
            if await heldAlready(error) { return true }
            // Said each time, so the Sync Log shows why a file stays unheld (a suite run at 16:55
            // had two new files unheld for a minute with nothing after the first failure).
            record("pause", detail: "not held on try \(tries): \(Self.pauseTrouble(error))")
            return false   // "not supported" included: next time
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
        uploads.edited()
        let over = (editor.textView.textStorage?.length ?? 0) > Editor.highlightLimit
        if over != highlightingOff { highlightingOff = over }
        // The copy's line stays (nothing's saved till the file's here), and so does a problem: the
        // first keystroke took a deleted file's, iCloud Drive off's or a full disk's red line away
        // for good (the QA review's F5). A save that lands, or the problem's end, sets it again.
        if !awaitingDownload, !state.isProblem { state = .editing }
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
        // A big edit (an open, a paste, a reload) goes straight to the search for blocks, which
        // looks for a start marker once: here it would look for all four first (120 ms of a 5 MB
        // file's open, Debug; §6.5).
        if blocks.isEmpty, let edit = editor.lastEdit, edit.length < 65_536, let storage = editor.textView.textStorage {
            let text = storage.string as NSString
            let lines = text.lineRange(for: NSIntersectionRange(edit, NSRange(location: 0, length: text.length)))
            guard ["<<<<<<<", "|||||||", "=======", ">>>>>>>"].contains(where: { text.range(of: $0, range: lines).location != NSNotFound }) else { return }
        }
        // The storage's own string, not the view's copy of it.
        let found = ConflictText.blocks(in: editor.textView.textStorage?.string ?? editor.textView.string)
        if found.count != blocks.count { bannerHidden = false }
        if !blocks.isEmpty, found.isEmpty, editor.textView.window?.isVisible == true {
            Announce.sentence("No conflicts left in \(url.lastPathComponent).")   // AX2
        }
        if found.isEmpty { Notifier.shared.ended(.conflict, for: url) }   // SY15: resolved, or merged away
        if found != blocks {
            blocks = found
            DockBadge.shared.update()   // the Dock's ✕ while any file has blocks (AP8)
        }
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

    /// The banner's button: the merge view for more than three blocks (§5.5), else the next block.
    /// (⌥⌘R, Merge View…, always opens the merge view: F52.)
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

    /// This Mac's disk is full (§4.9, 13): the journal and the file both fail.
    static let diskFull = "DISK FULL · YOUR LATEST CHANGES ARE ONLY IN MEMORY · FREE SPACE OR COPY THEM"

    private func scheduleJournal(after delay: Double = 0.25) {
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.writeJournal()
        }
    }

    private func writeJournal() async {
        // The text as it is now; its SHA-256 (a snapshot's) is worked out on the journal's queue,
        // not here (8 ms at every pause, at 2.4 MB). A big text's journal takes only what changed.
        let text = editor.textView.string, path = url.path, base = baseFingerprint?.sha256, format = self.format
        let journal = self.journal
        do {
            #if DEBUG
            if TestHarness.diskFull { throw POSIXError(.ENOSPC) }   // the `full` scenario
            #endif
            try await journalQueue.run { try journal.record(path: path, text: text, baseSHA256: base, format: format) }
        } catch {
            // The one case where text lives only in memory (§4.9, 13): say so loudly, and try
            // again in 15 s, typing or not.
            state = .problem(CloudControl.isOutOfSpace(error) ? Self.diskFull
                             : "COULDN'T WRITE THE RECOVERY JOURNAL · \(short(error)) · YOUR LATEST TYPING IS ONLY IN MEMORY")
            Notifier.shared.began(CloudControl.isOutOfSpace(error) ? Alerts.diskFull(url.lastPathComponent)
                                  : Alerts.journalFailed(url.lastPathComponent, why: short(error)), for: url)
            if CloudControl.isOutOfSpace(error) { diskIsFull(at: journal.directory) }
            record("problem", detail: "journal: \(CloudControl.describe(error))")
            scheduleJournal(after: 15)
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
        let defaults = NibDefaults.store
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
        guard ready, locked == nil, !closed else { return }
        saveTask?.cancel()
        // A save already running (the app switch's, say) would make this one step aside and
        // return before the file has the text: wait for it, then save what's still unsaved.
        for _ in 0..<250 where saving { try? await Task.sleep(for: .milliseconds(20)) }
        if dirty { await save(reason: reason) }
        if held, uploadedSHA != baseFingerprint?.sha256 { await upload(now: true) }
    }

    func save(reason: String) async {
        // While the copy is shown (§4.8 F), typing goes to the journal only: the file isn't here.
        guard ready, locked == nil, dirty, !deleted || iCloudOff, !awaitingDownload, !closed else { return }   // F2
        if iCloudOff { await saveToRecovery(); return }
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
        let format = self.format
        let base = baseFingerprint
        let url = self.url
        let presenter = self.presenter
        let started = Date()
        do {
            #if DEBUG
            if TestHarness.diskFull { throw POSIXError(.ENOSPC) }   // the `full` scenario
            #endif
            // When the write itself began: a slow save is either a wait behind other file work on
            // this queue or a slow coordinated write, and the Sync Log says which (the two-Mac runs
            // on the evening of 2026-09-29 had saves of 1-11 s, against under 0.5 s at 10:55).
            // The text is encoded there too, not on the main thread, which it held for ~150 ms a
            // save at 42 MB (ED9) and ~9 ms at the scratch file's 2.4 MB.
            let (outcome, began, data) = try await io.run { () throws -> (WriteOutcome, Date, Data) in
                let began = Date()
                let data = TextFile.encode(text, as: format)
                return (try FileAccess.write(data, to: url, base: base, presenter: presenter), began, data)
            }
            switch outcome {
            case .written(let fingerprint, let changed):
                schedule.wrote(changed)
                if let sha = fingerprint.sha256 { madeHere[sha] = Date() }
                if madeHere.count > 50, let oldest = madeHere.min(by: { $0.value < $1.value })?.key { madeHere[oldest] = nil }
                baseFingerprint = fingerprint
                if held { savedWhileHeld = fingerprint.sha256 }
                remember(text, sha: fingerprint.sha256)
                fileBytes = data.count
                historySaved(data, parent: base?.sha256, sha: fingerprint.sha256, keep: reason == "merge")
                if !pendingResolved.isEmpty || !pendingTrash.isEmpty { settleOthers() }
                savedEditCount = snapshot
                lastSaved = Date()
                savedAt = lastSaved
                let journal = self.journal, path = url.path
                if recoveryPending {
                    // The file has the text now: the Recovery folder's copy isn't needed.
                    recoveryPending = false
                    let copy = recoveryURL.deletingLastPathComponent()
                    Task { await io.run { try? FileManager.default.removeItem(at: copy) } }
                }
                if !dirty {
                    schedule.saved()
                    Task { await journalQueue.run { journal.clear(path: path) } }   // in order with its writes
                } else {
                    // Typing went on during the save: the journal says it's from the new version
                    // now (a crash before the next pause recovered it as a conflict with the file).
                    Task { await writeJournal() }
                }
                state = dirty ? .editing : untitled ? .local(lastSaved) : savedState(lastSaved)
                let waited = began.timeIntervalSince(started)
                record("save", size: data.count, sha: fingerprint.sha256, ms: ms(since: started),
                       detail: waited > 0.5 ? "\(reason) · \(ms(since: started) - Int(waited * 1000)) ms writing, after \(Int(waited * 1000)) ms waiting behind other file work" : reason)
                uploadNow = reason != "debounce"
            case .diskChanged(let onDisk, let fingerprint):
                record("save", detail: "refused: the file changed on disk since it was loaded")
                saving = false
                incoming(onDisk, fingerprint: fingerprint, from: "the file")
                if dirty { scheduleSave() }   // what's still unsaved: saved again (it sat unsaved until quit at 20:55)
                return
            }
        } catch where (error as? CocoaError)?.code == .fileNoSuchFile {
            // The file is gone, and the notice of it hasn't come (or went to a presenter that
            // followed it to the Trash): deleted (§4.8 E).
            saving = false
            markDeleted(trash: false)
            return
        } catch {
            state = .problem(CloudControl.isOutOfSpace(error) ? Self.diskFull
                             : "COULDN'T SAVE \(url.lastPathComponent.uppercased()) · \(short(error)) · YOUR TEXT IS IN NIB'S RECOVERY JOURNAL")
            Notifier.shared.began(CloudControl.isOutOfSpace(error) ? Alerts.diskFull(url.lastPathComponent)
                                  : Alerts.saveFailed(url.lastPathComponent, why: short(error)), for: url)
            if CloudControl.isOutOfSpace(error) { diskIsFull(at: url) }
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

    /// One at a time; while typing goes on, as `UploadSchedule` says (3 s after it pauses, or every
    /// 20 s); `now`, on a trigger, at once.
    private func upload(now: Bool) async {
        #if DEBUG
        if NibDefaults.store.bool(forKey: "NibHoldUploads") { return }   // the "unsent" scenario
        #endif
        guard held, !deleted, online || now else {
            if held, !online { state = .waiting("WAITING FOR NETWORK · SAVED LOCALLY \(SyncState.clock.string(from: lastSaved))") }
            return
        }
        guard !uploading else { uploadAgain = true; return }
        // Nothing saved since the last upload began, and it took this version: nothing to send. The
        // upload waiting for typing's pause went anyway after one made at once (⌘S, another app in
        // front), the same version twice (the suite, 2026-10-07: 2.8 s, then 0.8 s more). A save
        // since, even of the same text (an undo back to it), goes: only the upload can say whether
        // another Mac's is newer.
        if uploadedSHA != nil, uploadedSHA == baseFingerprint?.sha256, let began = uploadBegan, lastSaved < began {
            uploadTask?.cancel()
            return
        }
        guard !refreshing else {
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.upload(now: now)
            }
            return
        }
        let wait = now ? 0 : max(0, uploads.due.timeIntervalSinceNow)
        if wait > 0 {
            uploadTask?.cancel()
            uploadTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                // Typing since may have moved the moment on (its pause is later now): looked at
                // again, and waited for again if so (the `uploads` scenario, 2026-10-06: without
                // this, each save's upload went 3 s after it, every 5-6 s, as before).
                await self.upload(now: self.uploads.due.timeIntervalSinceNow <= 0.05)
            }
            return
        }
        uploading = true
        uploads.started()
        uploadBegan = Date()
        let sha = baseFingerprint?.sha256
        if !dirty { state = .uploading(lastSaved) }
        let started = Date()
        do {
            #if DEBUG
            if TestHarness.storageFull {   // the `full` scenario: iCloud storage full
                throw NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileNotUploadedDueToQuotaError)
            }
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
            if CloudControl.isQuota(error) {
                // §4.9, 12: red, and kept trying (the backoff, to 5 minutes) until there's room.
                state = .problem("ICLOUD STORAGE IS FULL · SAVED LOCALLY ONLY · RETRYING")
                Notifier.shared.began(Alerts.storageFull(url.lastPathComponent), for: url)
            } else {
                // Why, and when it's tried again (F42: "RETRYING", with no reason or time). A wait,
                // dim, not red: it goes on by itself (§4.5, L6).
                let delay = noAnswer ? 2 : uploadBackoff
                let again = "TRYING AGAIN AT \(SyncState.clock.string(from: Date().addingTimeInterval(delay)))"
                state = .waiting(!online ? "WAITING FOR NETWORK · SAVED LOCALLY"
                                 : noAnswer ? "ICLOUD ISN'T ANSWERING · SAVED LOCALLY · \(again)"
                                 : "ICLOUD ISN'T TAKING UPLOADS · \(ErrorWords.hud(error)) · SAVED LOCALLY · \(again)")
            }
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
                // Nothing newer anywhere, and iCloud has what's here: synced, as it was. Its time is
                // when iCloud took this version, not when Nib last asked: "✓ SYNCED · 10:42:07" moved
                // on every 30 s and at every focus (the QA review's F7).
                if !dirty, !uploading, uploadedSHA != nil, uploadedSHA == baseFingerprint?.sha256, !state.isSynced {
                    state = .synced(uploadedAt ?? Date())
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
                let note = await notesQueue.run { Announcement.read(for: url) }
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
        if deleted { await deletedFileBack(); return }
        // Not on this Mac yet: a read now would wait for the download (`awaitDownload` brings it).
        guard ready, locked == nil, !saving, !refreshing, fetches == 0, !awaitingDownload else { return }
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

    /// Whether the buffer is `text`, exactly (`TextDelta.same`: not Swift's ==, 78 ms at 2.4 MB).
    private func holds(_ text: String) -> Bool {
        TextDelta.same(editor.textView.textStorage?.string as NSString? ?? editor.textView.string as NSString, text as NSString)
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
        if holds(theirs) {
            baseFingerprint = fingerprint
            if let fingerprint { savedAt = Date(timeIntervalSince1970: fingerprint.modified) }
            savedEditCount = editCount
            if fromServer { uploadedSHA = fingerprint?.sha256 }
            return
        }
        if !unsent {
            apply(theirs)
            record("update", sha: fingerprint?.sha256, detail: "nothing unsent here: the buffer is now \(source)'s version")
            baseFingerprint = fingerprint
            if let fingerprint { savedAt = Date(timeIntervalSince1970: fingerprint.modified) }
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
        // The other side's name: a Mac's, or the source's: "iCloud" as Apple writes it (it came out
        // "ICloud" in the markers, the banner, the menu and the notification: the QA review's F9),
        // "Another Mac" heading a marker, "another Mac" in a sentence.
        let who = proven?.device ?? source
        let label = proven?.device ?? Self.label(source)
        let mySide = ConflictText.Side(text: mine, label: "\(device) · \(clock)")
        let theirSide = ConflictText.Side(text: theirs, label: "\(label) · \(clock)")
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
        // Merged: the places both changed. Not: both whole versions, which isn't "1 place" (F14).
        show(merged ? "✕ CONFLICT WITH \(who.uppercased()) · \(places) PLACE\(places == 1 ? "" : "S") · BOTH VERSIONS ARE IN THE TEXT"
                    : "✕ CONFLICT WITH \(who.uppercased()) · BOTH WHOLE VERSIONS ARE IN THE TEXT", for: 10)
        NSApp.requestUserAttention(.informationalRequest)
        Notifier.shared.began(Alerts.conflict(url.lastPathComponent, with: who, places: places, whole: !merged), for: url)
    }

    /// Blocks were written two-way, and now a note proves the base: if the text is as it was
    /// written, the three-way merge replaces them (clean, or with smaller blocks).
    private func upgradeIfProven() {
        guard let pending = unproven, let proven = provenBase(for: pending.theirsSHA, uploaded: pending.uploadedBefore) else { return }
        unproven = nil
        guard holds(pending.written) else { return }   // edited since: left as written
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
        if NibDefaults.store.array(forKey: known) == nil { NibDefaults.store.set(found.map(\.lastPathComponent), forKey: known) }
        let before = Set(NibDefaults.store.stringArray(forKey: known) ?? [])
        for duplicate in found where !before.contains(duplicate.lastPathComponent) {
            guard let (data, _) = try? await othersQueue.run({ try FileAccess.read(duplicate) }) else { continue }
            handleDuplicate(duplicate, data)
        }
    }

    // MARK: - History (SY13)

    /// Bumped with every version History keeps, so Revert To and the History window follow.
    private(set) var historyChanged = 0
    /// History's versions, oldest first, as last read off the main thread. The History window
    /// and Revert To read the index from disk in their `body`, at every redraw and menu update,
    /// on the main thread (the QA review's F57).
    private(set) var historyEntries: [HistoryEntry] = []

    /// History changed (or the file opened): its versions read again, off the main thread and
    /// off the journal's queue (History has its own lock): on the queue, the read of every
    /// version's line held up the journal, and so a merge's save, behind it.
    func reloadHistory() async {
        let history = self.history
        historyEntries = await Task.detached(priority: .utility) { history.entries() }.value
        historyChanged += 1
    }

    private func recordHistory(_ work: @escaping @Sendable (History) -> Void) {
        let history = self.history, pending = takePendingHistory()   // first, so History stays in order
        Task {
            await journalQueue.run {
                if let pending { try? history.record(pending.data, parent: pending.parent, source: "saved", time: pending.time) }
                work(history)
            }
            await reloadHistory()
        }
    }

    /// How often History is thinned while the file stays open: once a day.
    static var thinEvery: TimeInterval {
        #if DEBUG
        let every = NibDefaults.store.double(forKey: "NibThinEvery")   // -NibThinEvery <seconds>, for a scenario
        if every > 0 { return every }
        #endif
        return 86_400
    }

    @ObservationIgnored private var thinTask: Task<Void, Never>?

    /// History thinned (SY13) as the file opens, then once a day until it closes. It was thinned
    /// only at open, and Nib runs for days or weeks with the scratch file open (SC1): every version
    /// History kept for it stayed at full density until the next launch, up to 29 MB an hour of
    /// typing at 2.4 MB (2026-10-02, PRD §8). On the journal's queue: off the main thread, and in
    /// order with History's writes.
    private func thinHistory() {
        thinTask?.cancel()
        let history = self.history, queue = journalQueue, every = Self.thinEvery
        thinTask = Task { [weak self] in
            repeat {
                if await queue.run({ history.thin() }) { await self?.reloadHistory() }   // the History window follows
                try? await Task.sleep(for: .seconds(every))
            } while !Task.isCancelled && self?.closing == false
        }
    }

    /// Once the History writes queued so far are done (they go in order on the journal's queue):
    /// a closed untitled buffer's History is carried or let go only after its last version (ED3).
    func historyWritten() async {
        await journalQueue.run {}
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
                // Within what's left of the wait: a fresh read waits for iCloud to bring the note
                // down, and with its daemons busy one held this wait past 15 s (the suite,
                // 2026-10-01). A note that comes later still narrows the blocks (`upgradeIfProven`).
                let queue = notesQueue, left = max(0.25, deadline.timeIntervalSinceNow)
                if let note = try? await CloudControl.within(left, { await queue.run { Announcement.read(for: url, fresh: true) } }), note.sha256 == sha {
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
        guard !closing, let data = history.data(entry.sha256) else { NSSound.beep(); return }   // F2
        let text = TextFile.decode(data).text
        guard !holds(text) else { return }
        // Named as History and Revert To name it: a version can be 30 days old, and the time of
        // day alone read as today's (the QA review's F20).
        let time = HistoryView.when(entry.time)
        replaceBuffer(with: text, action: "Revert to \(time)")
        show("= BACK TO THE VERSION FROM \(time.uppercased()) (\(entry.source.uppercased())) · ⌘Z UNDOES", for: 10)
        record("revert", sha: entry.sha256, detail: "to the version from \(time) (\(entry.source))")
    }

    /// A version this Mac has already had: identical to the buffer or the file, taken in
    /// before, or one History knows (kept, or saved here and not kept). Its text adds nothing.
    private func alreadyHave(_ text: String, sha: String) -> Bool {
        holds(text) || sha == baseFingerprint?.sha256 || incorporated.contains(sha)
            || superseded.contains(sha) || history.has(sha)
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
        let identical = holds(theirs) || sha == baseFingerprint?.sha256
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
        keptAs = Self.historySource(for: action)
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

    /// The version's text, kept for later merges: the last eight, never the one on the server
    /// or the one blocks written two-way wait to merge from (`upgradeIfProven`). A merge's base
    /// is always one of those, so it never depends on History keeping it.
    private func remember(_ text: String, sha: String?) {
        guard let sha, versions[sha] == nil else { return }
        versions[sha] = text
        versionOrder.append(sha)
        // Two over 5 MB (ED9): eight copies of a 42 MB text were 670 MB of memory.
        let most = (text as NSString).length > Editor.highlightLimit ? 2 : 8
        let waiting = unproven?.uploadedBefore
        while versionOrder.count > most, let i = versionOrder.firstIndex(where: { $0 != uploadedSHA && $0 != waiting }) {
            versions[versionOrder.remove(at: i)] = nil
        }
    }

    /// Replaces the buffer, keeping the caret near where it was. One undo step.
    private func apply(_ text: String, undoable: Bool = true) {
        let view = editor.textView
        let selection = view.selectedRange()
        applying = true
        // Only what changed (§6.5): another version usually differs in a few lines, and
        // replacing the whole text redid TextKit's layout, the line index and the undo step for
        // all of it (a reload at 2.4 MB, 303 ms in Debug).
        let current = view.textStorage?.string as NSString? ?? view.string as NSString
        let change = TextDelta.change(from: current, to: text as NSString)
        if let change {
            if undoable, view.shouldChangeText(in: change.range, replacementString: change.replacement) {
                view.textStorage?.replaceCharacters(in: change.range, with: change.replacement)
                view.didChangeText()
            } else {
                // Not undoable, or the view won't take an edit (read-only): the whole text, as before.
                view.string = text
                editor.scheduleHighlight(after: 0)
            }
        }
        applying = false
        // The caret where it was, moved along by a change before it.
        let length = (text as NSString).length
        var location = selection.location
        if let change, location >= NSMaxRange(change.range) {
            location += (change.replacement as NSString).length - change.range.length
        } else if let change, location > change.range.location {
            location = change.range.location + (change.replacement as NSString).length
        }
        view.setSelectedRange(NSRange(location: min(max(0, location), length), length: 0))
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
    /// `fresh` asks the server (evicting the note and reading it back); a check set off by the
    /// note or its folder changing on disk reads what's there. Each fresh read's eviction and
    /// download changed the folder, and the check that set off evicted the note again: from the
    /// first eviction that took, the note went back and forth to iCloud every second or two for
    /// as long as the file was open, frontmost or not, and the notes queue, never idle, kept what
    /// each read let go of (the Nib in daily use grew about 180 MB an hour while idle; 2026-10-02,
    /// PRD §8). One check at a time: one asked for meanwhile runs once after it.
    func checkAnnouncement(reason: String, fresh: Bool = true) async {
        // Not offline: a fresh read evicts the note and waits for it to download again.
        guard ready, locked == nil, !refreshing, !closing, !offlineNow else { return }
        guard !checkingNote else {
            noteAgain = (reason, fresh || noteAgain?.fresh == true)
            return
        }
        checkingNote = true
        let url = self.url, queue = notesQueue
        #if DEBUG
        if fresh { noteReads.fresh += 1 } else { noteReads.local += 1 }
        #endif
        let read = try? await CloudControl.within(10, { await queue.run { Announcement.read(for: url, fresh: fresh) } })
        checkingNote = false
        if let again = noteAgain {
            noteAgain = nil
            Task { await checkAnnouncement(reason: again.reason, fresh: again.fresh) }
        }
        guard let note = read else { return }
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

    // MARK: - Receipts (SY14, §4.5)

    /// The other Macs' receipts changed (ReceiptBook).
    func receiptsChanged() { updateOtherMacs() }

    /// Whether this Mac has seen a version: had it, saved it, moved past it or merged it in.
    private func seen(_ sha: String) -> Bool {
        sha == baseFingerprint?.sha256 || sha == uploadedSHA || superseded.contains(sha) || incorporated.contains(sha)
            || handledAnnouncements.contains(sha) || versions[sha] != nil || madeHere[sha] != nil || history.has(sha)
    }

    private func updateOtherMacs() {
        guard ready, locked == nil, let base = baseFingerprint?.sha256, ReceiptBook.applies(to: url) else {
            if !otherMacs.isEmpty { otherMacs = [] }
            return
        }
        let now = ReceiptBook.shared.others(for: url).map {
            OtherMac(device: $0.device, loaded: $0.loaded, delivery: Delivery.of($0.loaded.sha256, base: base, known: seen))
        }
        guard now != otherMacs else { return }
        otherMacs = now
        for other in now {
            switch other.delivery {
            case .same:
                // How long a version made here took to reach the other Mac and be said back (T3).
                guard let made = madeHere[base], loggedReceipts.insert("\(other.device) \(base)").inserted else { continue }
                let since = uploadedSHA == base ? (uploadedAt ?? made) : made
                record("receipt", sha: base, ms: Int(Date().timeIntervalSince(since) * 1000),
                       detail: "\(other.device) has this version, \(Int(Date().timeIntervalSince(since).rounded())) s after this Mac \(uploadedSHA == base ? "uploaded" : "saved") it")
            case .newer:
                guard loggedReceipts.insert("\(other.device) \(other.loaded.sha256)").inserted else { continue }
                record("receipt", sha: other.loaded.sha256, detail: "\(other.device) has a version this Mac hasn't seen: asking for the note")
                Task { await checkAnnouncement(reason: "a receipt") }   // it may be here already
            case .earlier:
                continue
            }
        }
    }

    /// The strip's words: the state, with what the receipts say while it's synced (§4.5):
    /// "✓ SYNCED · ON STUDIO 10:42:31", or "▼ NEWER ON AIR (10:42) · NOT HERE YET".
    var statusLine: String {
        if case .saved = state, let stalledMinutes {
            return state.line + " · ICLOUD HASN'T STARTED UPLOADING (\(stalledMinutes) MIN)"
        }
        guard case .synced = state else { return state.line }
        if let newer = otherMacs.first(where: { $0.delivery == .newer }) { return newer.line }
        let same = otherMacs.filter { $0.delivery == .same }
        guard let latest = same.map(\.loaded.time).max() else { return state.line }
        return "✓ SYNCED · ON \(same.map { $0.device.uppercased() }.joined(separator: ", ")) \(SyncState.stamp(latest))"
    }

    /// The same for VoiceOver.
    var statusSpoken: String {
        guard case .synced = state else { return state.spoken }
        if let newer = otherMacs.first(where: { $0.delivery == .newer }) { return newer.sentence }
        let same = otherMacs.filter { $0.delivery == .same }
        guard let latest = same.map(\.loaded.time).max() else { return state.spoken }
        return "\(state.spoken), and on \(same.map(\.device).joined(separator: " and ")) since \(SyncState.spokenStamp(latest))"
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
            Task { @MainActor in await self?.checkAnnouncement(reason: "note folder changed", fresh: false) }
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
        guard ready, !held, !dirty, !awaitingDownload else { return }
        let url = self.url
        Task {
            guard let status = await CloudControl.status(url, within: 5), ready, !held, !dirty else { return }
            if status.uploading {
                state = .uploading(lastSaved)
            } else if status.uploaded, !state.isSynced {
                // iCloud took this Mac's save itself: synced, at the time it said so (and kept, as F7).
                uploadedAt = Date()
                state = .synced(uploadedAt ?? Date())
            }
        }
    }

    /// The file was deleted (by another app, or on another Mac: the two-Mac probe), or moved to
    /// this Mac's Trash by another app (§4.8 E, §4.9 8): the text
    /// stays, journaled as typing goes on, and nothing saves it or makes the file again by itself
    /// (the delete may have been meant). The banner offers Restore (the text written back where
    /// it was, held and uploaded) and Close (the text kept in History, on Reopen Closed File); the
    /// scratch file, Restore only. A file there again is taken as another app's version.
    private(set) var deleted = false
    private(set) var deletedToTrash = false

    /// iCloud Drive went off on this Mac, or its account signed out, and the file went with it
    /// (§4.9, 11): its removal comes as a deletion, with no iCloud account left. The text stays,
    /// saved to Nib's Recovery folder (never marked saved: it isn't in the file), and the file,
    /// back with iCloud, is merged with it as one there again after a deletion is.
    private(set) var iCloudOff = false
    @ObservationIgnored private var recoveryPending = false

    /// Whether this Mac is signed in to iCloud with iCloud Drive on.
    static var cloudIdentity: Bool {
        #if DEBUG
        if TestHarness.iCloudOff { return false }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    /// `Recovery/<the file's key>/<its name>` in Nib's Application Support folder.
    var recoveryURL: URL {
        NibPaths.support.appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(String(Digest.sha256(url.path).prefix(20)), isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    func fileWasDeleted() { markDeleted(trash: false) }

    private func markDeleted(trash: Bool) {
        guard !deleted else { return }
        deleted = true
        deletedToTrash = trash
        iCloudOff = !trash && ReceiptBook.applies(to: url) && !Self.cloudIdentity
        saveTask?.cancel()
        uploadTask?.cancel()
        holdRetry?.cancel()
        held = false   // nothing there to hold, or to hand back
        pausedFiles.remove(url.path)
        if iCloudOff {
            state = .problem("ICLOUD DRIVE IS OFF ON THIS MAC · SAVING TO NIB'S RECOVERY FOLDER")
            Notifier.shared.began(Alerts.iCloudOff(url.lastPathComponent), for: url)
            record("problem", detail: "the file went with iCloud Drive (no iCloud account on this Mac): saving to the Recovery folder")
            recoveryPending = true
            if dirty { scheduleSave(after: 0) }
            return
        }
        state = .problem("\(trash ? "MOVED TO THE TRASH" : "DELETED") · YOUR TEXT IS STILL HERE · RESTORE PUTS IT BACK")   // the name's in the title and the banner
        Notifier.shared.began(Alerts.deleted(url.lastPathComponent, trash: trash), for: url)
        record("problem", detail: trash ? "the file was moved to the Trash" : "the file was deleted")
    }

    /// The banner's Restore: the text written where the file was, made anew (unless a file is
    /// there again by now: then that's taken in, not overwritten), then held, once iCloud has
    /// it (§4.3), and uploaded.
    func restoreDeleted() async {
        guard deleted else { return }
        let text = editor.textView.string, data = TextFile.encode(text, as: format)
        let url = self.url, presenter = self.presenter, snapshot = editCount
        // The presenter followed a move to the Trash: it presents the file's own path again.
        NSFileCoordinator.removeFilePresenter(presenter)
        presenter.repoint(to: url)
        NSFileCoordinator.addFilePresenter(presenter)
        do {
            let outcome = try await io.run { try FileAccess.write(data, to: url, base: nil, presenter: presenter) }
            deleted = false
            switch outcome {
            case .written(let fingerprint, _):
                baseFingerprint = fingerprint
                savedEditCount = snapshot
                lastSaved = Date()
                savedAt = lastSaved
                remember(text, sha: fingerprint.sha256)
                recordHistory { history in try? history.record(data, parent: nil, source: "restored") }
                record("save", size: data.count, sha: fingerprint.sha256, detail: "restored where it was deleted")
                state = savedState(lastSaved)
                if !dirty {
                    let journal = self.journal, path = url.path
                    Task { await journalQueue.run { journal.clear(path: path) } }
                }
                guard !untitled else { return }
                do {
                    let waited = try await pauseFile()
                    held = true
                    pausedFiles.add(url.path)
                    record("pause", detail: Self.uploadWait(waited))
                    await upload(now: true)
                } catch {
                    record("pause", detail: "not held yet, after a restore: \(Self.pauseTrouble(error)); trying again in 2 s")
                    scheduleHoldRetry()
                }
            case .diskChanged(let onDisk, let fingerprint):
                record("reload", sha: fingerprint.sha256, detail: "restoring: a file is there again")
                incoming(onDisk, fingerprint: fingerprint, from: "another app")
            }
        } catch {
            state = .problem("COULDN'T RESTORE \(url.lastPathComponent.uppercased()) · \(short(error)) · YOUR TEXT IS STILL HERE AND IN THE JOURNAL")
            record("problem", detail: "restoring: \(CloudControl.describe(error))")
        }
    }

    /// While deleted: a file there again (another app saving it anew, or iCloud Drive on again)
    /// is that version, merged with the typing here.
    private func deletedFileBack() async {
        guard deleted, FileManager.default.fileExists(atPath: url.path) else { return }
        if iCloudOff, !Self.cloudIdentity { return }
        let url = self.url, presenter = self.presenter
        guard let (data, fingerprint) = try? await io.run({ try FileAccess.read(url, presenter: presenter) }), deleted else { return }
        let back = iCloudOff
        deleted = false
        iCloudOff = false
        state = dirty ? .editing : savedState(lastSaved)
        record("reload", size: data.count, sha: fingerprint.sha256, detail: back ? "the file is back with iCloud Drive" : "the file is there again")
        incoming(data, fingerprint: fingerprint, from: back ? "iCloud" : "another app")
        if dirty { scheduleSave(after: 0) }
        if !untitled { scheduleHoldRetry() }
    }

    /// While iCloud Drive is off: the text, in Nib's Recovery folder.
    private func saveToRecovery() async {
        let data = TextFile.encode(editor.textView.string, as: format), target = recoveryURL
        do {
            try await io.run {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
            record("save", size: data.count, detail: "to the Recovery folder (iCloud Drive is off): \(target.path)")
        } catch {
            state = .problem(CloudControl.isOutOfSpace(error) ? Self.diskFull
                             : "COULDN'T SAVE TO THE RECOVERY FOLDER · \(short(error)) · YOUR TEXT IS IN NIB'S RECOVERY JOURNAL")
            Notifier.shared.began(CloudControl.isOutOfSpace(error) ? Alerts.diskFull(url.lastPathComponent)
                                  : Alerts.saveFailed(url.lastPathComponent, why: short(error), toRecovery: true), for: url)
            if CloudControl.isOutOfSpace(error) { diskIsFull(at: recoveryURL) }
            record("problem", detail: "saving to the Recovery folder: \(CloudControl.describe(error))")
            scheduleSave(after: 15)
        }
    }

    /// iCloud's account changed on this Mac (on again, signed in): a file that went with it is
    /// looked for, until it's back (iCloud brings its files down again over a minute or two).
    func cloudIdentityChanged() {
        guard iCloudOff, Self.cloudIdentity else { return }
        Task {
            for _ in 0..<60 where deleted {
                await deletedFileBack()
                if !deleted { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The text of a deleted file whose window closes: in History, on Reopen Closed File, as an
    /// untitled buffer's is (nothing to save it to).
    private func keepDeletedText() {
        let text = editor.textView.string
        guard !text.isEmpty else { return }
        let data = TextFile.encode(text, as: format)
        if let pending = takePendingHistory() { try? history.record(pending.data, parent: pending.parent, source: "saved", time: pending.time) }
        try? history.record(data, parent: baseFingerprint?.sha256, source: "deleted elsewhere")
        ClosedItems.shared.add(.init(path: url.path, name: url.lastPathComponent, untitled: true, sha256: Digest.sha256(data), time: Date()))
    }

    /// Another app (Finder, a shell) moved or renamed the file, or its folder (§4.9, 9 and 10):
    /// the buffer follows it. Its text goes into the journal under the new path, its caret,
    /// syntax and History with it; this document lets the file go without saving, uploading or
    /// handing it back at the old path, where nothing is; and the file opens again where it is
    /// now, held as one left paused (the pause went with it), any typing not in it yet recovered
    /// from the journal. The scratch file, or a move out of the test folders (§8), only says where.
    func fileMoved(to newURL: URL) {
        guard newURL.standardizedFileURL.path != url.standardizedFileURL.path, !following else { return }
        // Finder's Move to Trash is a move, into the Trash (iCloud Drive's own, for its files).
        if newURL.pathComponents.contains(".Trash") { markDeleted(trash: true); return }
        // Where it went, as Finder names it: the new name alone said "SCRATCH.MD MOVED TO SCRATCH.MD"
        // for a move to another folder (the QA review's F16).
        let name = (ScratchLocation.place(of: newURL) + " › " + newURL.lastPathComponent).uppercased()
        if self === Documents.scratch || untitled {
            record("problem", detail: "the file moved to \(newURL.path): not followed (the scratch file stays as Settings › Scratch & Sync has it)")
            state = .problem("\(url.lastPathComponent.uppercased()) MOVED TO \(name) · SETTINGS › SCRATCH & SYNC TO FOLLOW IT")
            return
        }
        if ScratchLocation.refusal(for: newURL) != nil {
            record("problem", detail: "the file moved to \(newURL.path), outside the test folders: not followed (§8)")
            state = .problem("\(url.lastPathComponent.uppercased()) MOVED OUT OF THE TEST FOLDERS · YOUR TEXT IS STILL HERE AND IN THE JOURNAL")
            return
        }
        following = true
        record("move", detail: "moved to \(newURL.path), by another app or on another Mac: following it")
        Task { await follow(to: newURL) }
    }

    @ObservationIgnored private var following = false

    private func follow(to newURL: URL) async {
        let old = url
        closing = true   // nothing more against the old path: holds, fetches, refreshes
        editor.textView.isEditable = false
        for task in [saveTask, uploadTask, journalTask, thinTask] { task?.cancel() }
        holdRetry?.cancel()
        fetchTimer?.invalidate()
        editor.saveSelection(for: old)
        // The text under the new path, as it is now: compared with the file when it opens there.
        let text = editor.textView.string, base = baseFingerprint?.sha256, format = self.format
        let journal = self.journal
        do {
            try await journalQueue.run { try journal.record(path: newURL.path, text: text, baseSHA256: base, format: format) }
        } catch {
            record("problem", detail: "following the move: couldn't journal the text under the new path: \(CloudControl.describe(error))")
        }
        await journalQueue.run { journal.remove(path: old.path) }
        NSFileCoordinator.removeFilePresenter(presenter)
        NSFileCoordinator.removeFilePresenter(notePresenter)
        fileWatch?.cancel()
        noteWatch?.cancel()
        pausedFiles.remove(old.path)
        await recordClosingVersion()   // a save waiting for its span's end, under the old path, then carried
        FileCommands.carrySettings(from: old, to: newURL)
        let window = editor.textView.window
        Documents.forget(self)
        RecentFiles.shared.remove(old)
        AppDelegate.openFile(newURL)
        window?.close()
    }

    // MARK: - Activation, network, quitting

    /// nib came forward: check the server now, then every 30 s while it stays in front.
    func becameActive() {
        if deleted { Task { await deletedFileBack() }; return }
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
        guard !watchingNetwork else { return }   // a monitor starts once
        watchingNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.online != up else { return }
                self.online = up
                // Showing the copy: offline, or online with iCloud slow (F15).
                if case .offline(let time, _) = self.state { self.state = .offline(time, slow: up) }
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
        downloadTask?.cancel()
        thinTask?.cancel()
        Notifier.shared.closed(url)
        // History first: a quit has 10 s (its watchdog), and iCloud's steps after the save can
        // take them all (the suite, 00:19: the version closed with was lost that way). A save
        // the closing itself makes goes in at once (`historySaved`).
        await recordClosingVersion()
        await letGo()
        closed = true
    }

    /// Made empty by opening it, and closed still empty: removed again, so a typo in
    /// `nib REAMDE.md` leaves nothing behind (the QA review's F3, 2026-10-07). Only while the file
    /// on disk is still empty: anything another app or Mac wrote meanwhile stays.
    func removeIfLeftEmpty() async -> Bool {
        guard let made = madeEmpty, baseFingerprint?.sha256 == made, !dirty, !deleted else { return false }
        let url = self.url
        let removed = await io.run { () -> Bool in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size == 0 else { return false }
            var error: NSError?
            var done = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
                done = (try? FileManager.default.removeItem(at: target)) != nil
            }
            return done
        }
        if removed { record("quit", detail: "made empty as it opened, and closed still empty: removed again") }
        return removed
    }

    /// Saves, uploads and hands the file back; a deleted file's text goes into History.
    private func letGo() async {
        if deleted {
            // Nothing to save to, or hand back: the text goes into History, on Reopen Closed File.
            journalTask?.cancel()
            keepDeletedText()
            let journal = self.journal, path = url.path
            await journalQueue.run { journal.remove(path: path) }
            NSFileCoordinator.removeFilePresenter(presenter)
            NSFileCoordinator.removeFilePresenter(notePresenter)
            fileWatch?.cancel()
            noteWatch?.cancel()
            record("quit", detail: "closing a deleted file: its text is in History, on Reopen Closed File")
            return
        }
        holdRetry?.cancel()
        for _ in 0..<200 where pausing { try? await Task.sleep(for: .milliseconds(100)) }   // a hold in flight (≤ 20 s)
        let started = Date()
        record("quit", detail: "closing")
        editor.saveSelection(for: url)
        await flush(reason: "quit")
        #if DEBUG
        // The `history` scenario: iCloud's steps from here taking longer than a quit's 10 s.
        if TestHarness.slowQuit { try? await Task.sleep(for: .seconds(15)) }
        #endif
        // Nothing unsaved: the journal goes, a big text's snapshot with it (a quit with unsent
        // edits writes it again, below), and a write still waiting on the last keystroke with it.
        // Unsaved (the save failed): the journal has every keystroke.
        journalTask?.cancel()
        if dirty {
            await writeJournal()
        } else {
            let journal = self.journal, path = url.path
            await journalQueue.run { journal.remove(path: path) }
        }
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
            // Gone (deleted, or taken away with iCloud Drive): nothing is paused to hand back. It
            // was tried again at every launch, and listed for good (the suite's test files).
            guard FileManager.default.fileExists(atPath: path) else { list.remove(path); continue }
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

    // MARK: - The Trash, for space (§4.9, 13)

    /// The disk holding `place` is full: the strip offers to empty its Trash, when that would
    /// give space back. Measured once each time it fills.
    private func diskIsFull(at place: URL) {
        guard fullVolume == nil else { return }
        fullVolume = place
        Task { trashOffer = await Self.offer(for: place) }
    }

    /// The Trash for the disk holding `place`: that drive's own, or the Mac's (Finder's).
    private static func trash(for place: URL) -> (folder: URL?, mac: Bool) {
        #if DEBUG
        // A scenario's Nib never offers or empties the Mac's Trash, only its own made-up one.
        if NibPaths.isScenario { return (TestHarness.fakeTrash, false) }
        #endif
        if let drive = TrashService.volumeTrash(containing: place) { return (drive, false) }
        return (TrashService.userTrash, true)
    }

    private static func offer(for place: URL) async -> TrashOffer? {
        guard let folder = trash(for: place).folder else { return nil }
        guard let contents = await TrashService.contents(of: folder) else { return TrashOffer(bytes: nil) }
        return contents.isEmpty ? nil : TrashOffer(bytes: contents.bytes)
    }

    /// EMPTY TRASH on the strip. Asks first: it can't be undone. A drive's own Trash Nib empties
    /// itself; the Mac's, Finder does (macOS asks once whether Nib may tell it to). Then the
    /// journal and the save try again at once, not at the next 15 s retry.
    func emptyTrashForSpace() async {
        guard let place = fullVolume else { return }
        let (folder, mac) = Self.trash(for: place)
        guard let folder else { return }
        var contents = await TrashService.contents(of: folder)
        var what = mac ? "the Trash" : "the Trash on “\(TrashService.volumeName(containing: place))”"
        if contents == nil, mac {
            // Nib can't look into the Mac's Trash: Finder counts it.
            guard let count = await TrashService.finderTrashCount() else {
                show("✕ NIB ISN'T ALLOWED TO CONTROL FINDER · SYSTEM SETTINGS › PRIVACY & SECURITY › AUTOMATION", for: 10)
                return
            }
            if count == 0 { contents = TrashService.Contents(items: 0, bytes: 0) } else { what = "the Trash (\(count) item\(count == 1 ? "" : "s"))" }
        }
        if contents?.isEmpty == true {
            NSSound.beep()
            trashOffer = nil
            show("✕ THE TRASH IS EMPTY · FREE SPACE ANOTHER WAY, OR COPY YOUR TEXT", for: 8)
            return
        }
        guard TrashService.confirm(what, contents) else { return }
        if mac {
            if let problem = await TrashService.emptyFinderTrash() {
                show(problem.hasPrefix("Nib isn't allowed") ? "✕ NIB ISN'T ALLOWED TO CONTROL FINDER · SYSTEM SETTINGS › PRIVACY & SECURITY › AUTOMATION"
                                                          : "✕ COULDN'T EMPTY THE TRASH", for: 10)
                record("problem", detail: "emptying the Trash for space: \(problem)")
                return
            }
        } else {
            let problems = await TrashService.erase(folder)
            if !problems.isEmpty {
                show("✕ \(problems.count) ITEM\(problems.count == 1 ? "" : "S") IN THE TRASH COULDN'T BE ERASED", for: 10)
                record("problem", detail: "emptying the Trash for space: \(problems.joined(separator: "; "))")
                return
            }
        }
        TrashService.playEmptySound()
        trashOffer = nil
        record("problem", detail: "the Trash emptied for space (\(contents.map { $0.bytes.formatted(.byteCount(style: .file)) } ?? "size unknown")): saving again")
        show("✓ TRASH EMPTIED · SAVING AGAIN", for: 4)
        scheduleJournal(after: 0)
        scheduleSave(after: 0)
    }

    // MARK: - Large files (ED9)

    /// Saves go into History, by the rule below, up to this size; above it, only the version
    /// closed with (and those opened, merged, restored, from other Macs), ED9.
    static let historyEverySave = 5_000_000

    /// Of the saves, History keeps the newest of each span: 5 minutes from the span's first save.
    static var historySpan: TimeInterval {
        #if DEBUG
        if let span = TestHarness.historySpan { return span }   // the `history` scenario's
        #endif
        return 300
    }

    /// The newest save of the span now running, waiting for its end to go into History.
    @ObservationIgnored private var historyPending: (data: Data, parent: String?, time: Date)?
    @ObservationIgnored private var historyTask: Task<Void, Never>?

    /// A save, for History (open question 22, the user's call: b). Every version opened, merged,
    /// from another Mac, restored or closed with goes in; of the plain saves, the newest of each
    /// five minutes: a save every 1-5 s of typing was 720 whole copies an hour, 1.7 GB at the
    /// scratch file's 2.4 MB, kept a day. Each save is known as seen, kept or not (receipts).
    /// What the next version to go into History at once is: a merge, the blocks written, Revert
    /// To, the merge view. History called them all "saved" (the QA review's F55).
    @ObservationIgnored private var keptAs: String?

    /// History's word for a version Nib changed the buffer to, from its undo action's name.
    static func historySource(for action: String) -> String {
        if action.hasPrefix("Merge from ") { return "merged from " + action.dropFirst("Merge from ".count) }
        if action.hasPrefix("Conflict with ") { return "both versions kept, with " + action.dropFirst("Conflict with ".count) }
        if action.hasPrefix("Revert to ") { return "restored from " + action.dropFirst("Revert to ".count) }
        if action == "Merge View" { return "from the merge view" }
        return action.lowercased()
    }

    private func historySaved(_ data: Data, parent: String?, sha: String?, keep: Bool) {
        let history = self.history
        if let sha { Task { await journalQueue.run { history.noteSeen(sha) } } }
        if closing {
            // The version closed with, whatever its size: in at once, before iCloud's steps.
            historyBehind = false
            recordHistory { history in try? history.record(data, parent: parent, source: "closed") }
            return
        }
        guard data.count <= Self.historyEverySave else {
            historyBehind = true   // the version closed with goes in (ED9)
            return
        }
        if keep {
            // Nib's own change (a merge, blocks written, Revert To): kept as it is, saying which.
            let source = keptAs ?? "saved"
            keptAs = nil
            recordHistory { history in try? history.record(data, parent: parent, source: source) }
            return
        }
        let starting = historyPending == nil
        historyPending = (data, parent, Date())
        guard starting else { return }
        let span = Self.historySpan
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(span))
            guard !Task.isCancelled else { return }
            self?.recordHistory { _ in }   // the span is over: its newest save goes in
        }
    }

    /// The save waiting for its span's end, to go into History now (something else goes in after it).
    private func takePendingHistory() -> (data: Data, parent: String?, time: Date)? {
        defer { historyPending = nil }
        historyTask?.cancel()
        historyTask = nil
        return historyPending
    }

    /// Closing: the version closed with into History, before the window (or Nib) goes: a save
    /// waiting for its span's end, or a big file's last save (`historyBehind`), once. A save the
    /// closing makes after this goes in by itself (`historySaved`).
    private func recordClosingVersion() async {
        let history = self.history, pending = takePendingHistory()
        let big = historyBehind && !dirty
        if big { historyBehind = false }
        let closed = big ? (data: TextFile.encode(editor.textView.string, as: format), parent: baseFingerprint?.sha256) : nil
        guard pending != nil || closed != nil else { return }
        await journalQueue.run {
            if let pending { try? history.record(pending.data, parent: pending.parent, source: "saved", time: pending.time) }
            if let closed { try? history.record(closed.data, parent: closed.parent, source: "closed") }
        }
        await reloadHistory()
    }

    // MARK: - Helpers

    /// The problems a notification was for (SY15), over once things are well again: a save that
    /// lands ends a failed save, and a deletion (restored); synced ends them all. Not on the
    /// states a retry passes through (uploading, waiting), or a full iCloud would be news again
    /// every few minutes.
    private func endAlerts(for state: SyncState) {
        let over: [Alerts.Kind]
        switch state {
        case .saved, .savedHere, .local: over = [.saveFailed, .deleted]
        case .synced: over = [.saveFailed, .deleted, .iCloudOff, .storageFull]
        default: return
        }
        for kind in over { Notifier.shared.ended(kind, for: url) }
    }

    func show(_ text: String, for seconds: Double) {
        notice = text
        // Said as well as shown, while the window is up (AX2: conflicts and merges announced).
        if editor.textView.window?.isVisible == true { Announce.hud(text, urgent: text.hasPrefix("✕")) }
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

    /// An error in a few words for the strip: "PERMISSION DENIED", "FILE IS LOCKED", "FOLDER IS
    /// GONE" (it was Cocoa's sentence uppercased, the file named twice: the QA review's F17).
    private func short(_ error: Error) -> String {
        let words = ErrorWords.hud(error)
        if words == "PERMISSION DENIED", (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable == true { return "FILE IS LOCKED" }
        if words == "FILE IS GONE", !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { return "FOLDER IS GONE" }
        return words
    }

    #if DEBUG
    /// For the test harness.
    var debugSnapshot: (dirty: Bool, uploadedSHA: String?, baseSHA: String?, held: Bool) {
        (dirty, uploadedSHA, baseFingerprint?.sha256, held)
    }
    /// The note read for another Mac's version, fresh from the server and as it is here (`writes`).
    @ObservationIgnored var noteReads = (fresh: 0, local: 0)
    #endif
}

// MARK: Indentation and Go to Line (ED6)

extension Document {
    /// For a file that doesn't show its own: Settings › Editor's (or Sublime's, imported).
    static var defaultIndentation: Indentation {
        let defaults = NibDefaults.store
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
        guard merge == nil, palette == nil, !paletteComing else { NSSound.beep(); return }
        let session = PaletteSession(kind, for: self)
        guard kind == .headings else { palette = session; return }
        // Go to Heading's list is made first: the sheet comes up with it (`PaletteSession.ready`).
        paletteComing = true
        Task {
            await session.ready()
            paletteComing = false
            if merge == nil, palette == nil { palette = session }
        }
    }


    /// The palette has gone: what was chosen in it, if anything.
    func finishPalette() {
        shownPalette?.finish()
        shownPalette = nil
    }

    /// ⌘R's pick (SC7): the caret at the heading's line, the heading near the top of the view,
    /// two lines above it in sight. Undo Selection (⌘U) goes back.
    func goToHeading(at location: Int) {
        let view = editor.textView
        view.window?.makeFirstResponder(view)
        let location = min(location, view.textStorage?.length ?? 0)
        view.setSelectedRange(NSRange(location: location, length: 0))
        // Put there, then again once TextKit has laid the text out there: from afar, it went where
        // TextKit guessed the line was, 26 lines off (`headings`).
        let line = editor.lineIndex.line(at: location)
        let top = editor.lineIndex.start(ofLine: max(1, line - 2)) ?? location
        editor.scroll(toTop: top)
        DispatchQueue.main.async { [weak self] in self?.editor.scroll(toTop: top) }
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
        view.reveal(location)
        return true
    }
}

// MARK: Syntax (HL1)

extension Document {
    /// The language the text is read as: the pick, or what the file's name and first line say.
    var language: SyntaxLanguage? {
        switch pickedSyntax {
        case nil: detectedSyntax
        case .plain: nil
        case .language(let language): language
        }
    }

    /// Picks the file's syntax from the strip or View › Syntax, kept for the file; nil is
    /// Automatic. Only the colors change: it isn't an edit.
    func pickSyntax(_ pick: SyntaxPick?) {
        pickedSyntax = pick
        NibDefaults.store.set(pick?.stored, forKey: "syntax:" + url.path)
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

    /// In the menus' order: plain text, then the languages by name.
    static let all: [SyntaxPick] = [.plain] + SyntaxLanguage.allCases.filter { $0 != .markdownInline }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map { .language($0) }

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
        // A pool drained after each job: a queue that's never idle (the notes queue in the loop
        // `checkAnnouncement` describes) otherwise keeps every autoreleased object it made.
        queue = DispatchQueue(label: label, qos: .userInitiated, autoreleaseFrequency: .workItem)
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
/// container like other apps' folders, with the sync notes hidden inside it. And the safety
/// rule (§8), which the test harness's Nib keeps: it opens only test files, in
/// iCloud Drive/Nib/Test/ (or, in ad-hoc builds that can't carry the iCloud entitlement,
/// iCloud Drive/nib-spike/).
enum ScratchLocation {
    static let containerID = "iCloud.com.banastas.nib"
    /// iCloud Drive/Nib/ on disk.
    static let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/iCloud~com~banastas~nib/Documents")
    static let testFolder = folder.appendingPathComponent("Test")
    static let unsignedTestFolder = NibPaths.iCloudDrive.appendingPathComponent("nib-spike")
    /// A test run's folder outside iCloud Drive, in the Mac's temporary folder: for files with nothing
    /// to sync (the QA review's F6), still none of the user's.
    static let localTestFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nib-local-test", isDirectory: true)

    /// Signed with the iCloud container (a team-signed build), or not (ad-hoc).
    static let hasContainer: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-container-identifiers" as CFString, nil) != nil
    }()

    /// The scratch file: the one Settings or the first run chose (SC1, AP5), or the standard one.
    static var url: URL {
        #if DEBUG
        // The scenarios use the test file the runner starts afresh, never the one this Mac uses;
        // -NibScenarioScratch <name>, another in the test folder: run-perf.sh's own, as
        // scratch-test.md is whatever a suite or a repro left (420 KB on 2026-10-02, and "idle
        // memory, a small scratch file" measured 132 MB).
        if NibDefaults.store.string(forKey: "NibScenario") != nil {
            guard let name = NibDefaults.store.string(forKey: "NibScenarioScratch") else { return testURL }
            return testURL.deletingLastPathComponent().appendingPathComponent(name)
        }
        #endif
        if let path = NibDefaults.store.string(forKey: "scratchPath") { return URL(fileURLWithPath: path) }
        return standardURL
    }

    /// iCloud Drive/Nib/scratch.md (SC1); the test file for the test harness's Nib.
    static var standardURL: URL {
        if hasContainer, !safetyRule { return folder.appendingPathComponent("scratch.md") }
        return testURL
    }

    static var testURL: URL { (hasContainer ? testFolder : unsignedTestFolder).appendingPathComponent("scratch-test.md") }

    /// The safety rule (§8): until M1 had passed, Nib opened only test files; a Mac with
    /// `allowLiveScratch` set opened any. Lifted on 2026-10-06 (the user's call): only the test
    /// harness's Nib keeps it, so a scenario never opens, moves or saves a file outside the test
    /// folders, and the Nib in daily use needs no setting.
    static var safetyRule: Bool { NibPaths.isScenario }

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
        guard safetyRule else { return nil }
        if Untitled.contains(url) { return nil }   // Nib's own, on this Mac only (ED3)
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(testFolder.path + "/") || path.hasPrefix(unsignedTestFolder.path + "/")
                || path.hasPrefix(localTestFolder.standardizedFileURL.path + "/") else {
            return "NIB OPENS ONLY TEST FILES IN A TEST RUN (ICLOUD DRIVE › NIB › TEST)"
        }
        return nil
    }
}
