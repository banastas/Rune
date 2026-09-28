// The scratch file, open in nib (PRD §4). The text view holds the buffer; this
// model journals it (SY1), saves it in place with compare-and-swap (SY2-SY4),
// holds the file with an iCloud sync pause and uploads each version itself with
// fail-on-conflict (§4.3), fetches newer versions when nib becomes active (§4.4),
// reloads when the file changes and there are no edits (SY5), and stops to ask
// when it changes while there are (SY6). Nothing is ever overwritten unseen.

import AppKit
import Network
import NibSync
import NibText
import Observation

/// Two versions to choose between (SY6).
struct Conflict: Identifiable {
    let id = UUID()
    /// The buffer: edits made on this Mac.
    var mine: ConflictText.Side
    /// What's in the file now.
    var theirs: ConflictText.Side
    var theirsFingerprint: Fingerprint?
    /// Theirs came from iCloud's server (so iCloud already has it), not from an app on this Mac.
    var theirsFromServer = false
}

@MainActor
@Observable
final class Document {
    let url: URL
    let device = Host.current().localizedName ?? "This Mac"
    private(set) var state: SyncState = .opening
    private(set) var format = FileFormat.standard
    /// A line that shows in the strip for a while ("▼ UPDATED FROM …", "RECOVERED …").
    private(set) var notice: String?
    var conflict: Conflict?
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
    @ObservationIgnored private let log = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))
    @ObservationIgnored private let pausedFiles = PausedFiles(url: NibPaths.support.appendingPathComponent("paused.json"))
    @ObservationIgnored private let io = IOQueue(label: "nib.io")
    @ObservationIgnored private let journalQueue = IOQueue(label: "nib.journal")

    /// The version the buffer came from, or was last saved as.
    @ObservationIgnored private var baseFingerprint: Fingerprint?
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
    /// A fetch is putting a newer version in place: its own change to the file isn't news.
    @ObservationIgnored private var fetching = false
    /// Announced versions already dealt with, by SHA-256.
    @ObservationIgnored private var handledAnnouncements: Set<String> = []
    /// Direct file-system watches, behind iCloud's presenters: writers that don't coordinate
    /// (`echo >> file`) went unnoticed by the presenter while a save waited to upload (M1).
    @ObservationIgnored private var fileWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var noteWatch: DispatchSourceFileSystemObject?

    var dirty: Bool { editCount != savedEditCount }

    /// Work on this Mac that no other Mac has: unsaved edits, or, for a held file, a saved
    /// version iCloud hasn't taken yet. Only a buffer with nothing unsent may be replaced by
    /// another version; anything else goes to the conflict sheet. (Two-Mac test, 09:25: a
    /// saved-but-refused version counted as clean and was replaced, losing its line.)
    var unsent: Bool { dirty || (held && uploadedSHA != baseFingerprint?.sha256) }

    init(url: URL) {
        self.url = url
        let defaults = UserDefaults.standard
        schedule = SaveSchedule(idle: defaults.object(forKey: "NibSaveIdle") as? TimeInterval ?? 1,
                                maxWait: defaults.object(forKey: "NibSaveMax") as? TimeInterval ?? 5)
        presenter = Presenter(url: url)
        notePresenter = NotePresenter(note: Announcement.url(for: url))
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
        let status = await io.run { CloudControl.status(url) }
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
        } catch {
            state = .problem("COULDN'T READ \(url.lastPathComponent.uppercased()) · \(short(error))")
            record("problem", detail: CloudControl.describe(error))
            return
        }
        applying = true
        editor.textView.string = text
        applying = false
        editor.restoreSelection(for: url)
        NSFileCoordinator.addFilePresenter(presenter)
        try? FileManager.default.createDirectory(at: Announcement.url(for: url).deletingLastPathComponent(), withIntermediateDirectories: true)
        NSFileCoordinator.addFilePresenter(notePresenter)
        watchFile()
        watchNoteFolder()
        record("open", size: text.utf8.count, sha: baseFingerprint?.sha256)
        recoverFromJournal(fileText: text)
        watchNetwork()
        state = status.uploaded ? .synced(Date()) : .saved(Date())
        ready = true
        await hold(status)
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
            editCount += 1
            show("RECOVERED TYPING FROM BEFORE NIB QUIT UNEXPECTEDLY · SAVING IT NOW", for: 20)
            record("recover", size: entry.text.utf8.count, detail: "journal from \(entry.written)")
        } else {
            // The file changed too: both versions, and the user decides.
            editCount += 1
            applying = true
            editor.textView.string = entry.text
            applying = false
            conflict = Conflict(mine: .init(text: entry.text, label: "\(device) · \(SyncState.clock.string(from: entry.written))"),
                                theirs: .init(text: fileText, label: "The file · now"),
                                theirsFingerprint: baseFingerprint)
            state = .conflict
            record("conflict", detail: "journal and file both changed")
        }
    }

    /// Pauses iCloud's own syncing of the file, when iCloud offers it (§4.3).
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
                try await CloudControl.resume(url, .uploadFailingOnConflict)
                record("resume", detail: "left paused by an earlier session; its saves are uploaded")
            } catch {
                // The server has something newer. Keep what's here for the conflict sheet, take
                // the server's version, and let the user choose (M1's two-way flow).
                let leftover = editor.textView.string
                try? await CloudControl.resume(url, .takeServerVersion)
                record("resume", detail: "left paused with unsent saves, and the server has a newer version: \(CloudControl.describe(error))")
                let presenter = self.presenter
                let url = self.url
                if let (data, fingerprint) = try? await io.run({ try FileAccess.read(url, presenter: presenter) }),
                   TextFile.decode(data).text != leftover {
                    editCount += 1   // the leftover counts as edits, so it reaches the sheet, not the void
                    incoming(data, fingerprint: fingerprint, from: "iCloud", fromServer: true)
                }
            }
        }
        do {
            try await CloudControl.pause(url)
            held = true
            pausedFiles.add(url.path)
            record("pause")
        } catch {
            record("pause", detail: "failed, running unheld: \(CloudControl.describe(error))")
        }
    }

    // MARK: - Editing

    /// From the editor, for every change the user makes.
    func textDidChange() {
        guard !applying, locked == nil else { return }
        editCount += 1
        schedule.edited()
        if conflict == nil { state = .editing }
        scheduleJournal()
        scheduleSave()
    }

    func selectionDidChange(line: Int, column: Int) {
        cursor = (line, column)
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
    func flush(reason: String) async {
        guard ready, locked == nil else { return }
        saveTask?.cancel()
        if dirty { await save(reason: reason) }
        if held, uploadedSHA != baseFingerprint?.sha256 { await upload(now: true) }
    }

    func save(reason: String) async {
        guard ready, locked == nil, dirty, conflict == nil else { return }
        if editor.textView.hasMarkedText() {   // mid-composition (IME): wait for the commit
            scheduleSave(after: 0.3)
            return
        }
        guard !saving else { scheduleSave(after: 0.2); return }
        saving = true
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
                savedEditCount = snapshot
                lastSaved = Date()
                if !dirty {
                    schedule.saved()
                    journal.clear(path: url.path)
                }
                if conflict == nil { state = dirty ? .editing : .saved(lastSaved) }
                record("save", size: data.count, sha: fingerprint.sha256, ms: ms(since: started), detail: reason)
                uploadNow = reason != "debounce"
            case .diskChanged(let onDisk, let fingerprint):
                record("save", detail: "refused: the file changed on disk since it was loaded")
                saving = false
                incoming(onDisk, fingerprint: fingerprint, from: "the file")
            }
        } catch {
            state = .problem("COULDN'T SAVE \(url.lastPathComponent.uppercased()) · \(short(error)) · YOUR TEXT IS IN NIB'S RECOVERY JOURNAL")
            record("problem", detail: "save: \(CloudControl.describe(error))")
            saving = false
            scheduleSave(after: 15)
            return
        }
        saving = false
        if dirty, conflict == nil { scheduleSave() }
        if let uploadNow { await upload(now: uploadNow) }
    }

    // MARK: - Uploading (held files, §4.3 step 7)

    /// At most every 3 s while typing continues, one at a time; `now` skips the spacing.
    private func upload(now: Bool) async {
        guard conflict == nil else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "NibHoldUploads") { return }   // the "unsent" scenario
        #endif
        guard held, online || now else {
            if held, !online { state = .waiting("WAITING FOR NETWORK · SAVED LOCALLY \(SyncState.clock.string(from: lastSaved))") }
            return
        }
        guard !uploading else { uploadAgain = true; return }
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
        if conflict == nil, !dirty { state = .uploading(lastSaved) }
        let started = Date()
        do {
            _ = try await CloudControl.upload(url)
            let parent = uploadedSHA
            uploadedSHA = sha
            uploadBackoff = 10
            record("upload", sha: sha, ms: ms(since: started))
            if let sha { announce(sha, parent: parent) }
            if conflict == nil, !dirty, baseFingerprint?.sha256 == sha { state = .synced(Date()) }
        } catch where CloudControl.isConflict(error) {
            record("upload", ms: ms(since: started), detail: "refused: the server has a newer version")
            uploading = false
            await fetchLatest(reason: "upload refused")
            return
        } catch {
            record("upload", ms: ms(since: started), detail: "failed: \(CloudControl.describe(error))")
            if conflict == nil {
                state = .waiting(online ? "ICLOUD ISN'T TAKING UPLOADS · SAVED LOCALLY · RETRYING" : "WAITING FOR NETWORK · SAVED LOCALLY")
            }
            let delay = uploadBackoff
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
        guard ready, locked == nil else { return }
        guard held else { await diskMayHaveChanged(); return }
        guard !uploading else { return }   // the upload itself is refused if the server is newer
        let url = self.url
        fetching = true
        defer { fetching = false }
        do {
            let result = try await CloudControl.fetchLatest(url)
            switch result {
            case .current:
                // Nothing newer anywhere, and iCloud has what's here: synced.
                if conflict == nil, !dirty, !uploading, uploadedSHA != nil, uploadedSHA == baseFingerprint?.sha256 {
                    state = .synced(Date())
                }
            case .newer(let data, let savedBy, _):
                let fingerprint = try? await io.run { () -> Fingerprint in
                    var fingerprint = try FileAccess.stat(url)
                    fingerprint.sha256 = Digest.sha256(data)
                    return fingerprint
                }
                record("fetch", size: data.count, sha: fingerprint?.sha256, detail: "newer, saved by \(savedBy ?? "another Mac") (\(reason))")
                // Replacing the local file may have ended the pause: hold it again.
                if CloudControl.status(url).paused != true {
                    try? await CloudControl.pause(url)
                }
                // iCloud often doesn't say which Mac saved it; the note does.
                let note = await io.run { Announcement.read(for: url) }
                let who = savedBy ?? note?.device ?? "another Mac"
                incoming(data, fingerprint: fingerprint, from: who, fromServer: true)
            }
        } catch {
            record("fetch", detail: "failed (\(reason)): \(CloudControl.describe(error))")
        }
    }

    /// The presenter or a check found the file different: look at what's there (§4.4 Check).
    func diskMayHaveChanged() async {
        guard ready, locked == nil, !saving, !refreshing, !fetching else { return }
        let url = self.url
        let presenter = self.presenter
        guard FileManager.default.fileExists(atPath: url.path),
              let current = try? await io.run({ try FileAccess.stat(url) }) else { return }
        if let base = baseFingerprint, current.sameStat(as: base) { return }
        guard let (data, fingerprint) = try? await io.run({ try FileAccess.read(url, presenter: presenter) }) else { return }
        if fingerprint.sha256 == baseFingerprint?.sha256 {
            baseFingerprint = fingerprint
            return
        }
        record("reload", size: data.count, sha: fingerprint.sha256, detail: "the file changed on disk")
        incoming(data, fingerprint: fingerprint, from: held ? "another app" : "iCloud")
    }

    /// A version nib didn't write. No local edits: it replaces the buffer. Edits: a conflict.
    private func incoming(_ data: Data, fingerprint: Fingerprint?, from source: String, fromServer: Bool = false) {
        let theirs = TextFile.decode(data).text
        let mine = editor.textView.string
        if theirs == mine {
            baseFingerprint = fingerprint
            savedEditCount = editCount
            if fromServer { uploadedSHA = fingerprint?.sha256 }
            return
        }
        if !unsent {
            apply(theirs)
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
        saveTask?.cancel()
        conflict = Conflict(mine: .init(text: mine, label: "\(device) · \(SyncState.clock.string(from: Date()))"),
                            theirs: .init(text: theirs, label: "\(source.capitalized) · \(SyncState.clock.string(from: Date()))"),
                            theirsFingerprint: fingerprint, theirsFromServer: fromServer)
        state = .conflict
        record("conflict", detail: "changed by \(source) while this Mac had \(dirty ? "unsaved edits" : "a saved version iCloud didn't have")")
        NSApp.requestUserAttention(.informationalRequest)
    }

    enum Choice: String { case mine, theirs, both }

    /// The conflict sheet's answer. The file already holds theirs; the base becomes it.
    func resolve(_ choice: Choice) {
        guard let conflict else { return }
        baseFingerprint = conflict.theirsFingerprint
        self.conflict = nil
        switch choice {
        case .mine:
            editCount += 1
        case .theirs:
            apply(conflict.theirs.text)
            savedEditCount = editCount
            if conflict.theirsFromServer { uploadedSHA = conflict.theirsFingerprint?.sha256 }
            journal.clear(path: url.path)
            state = .saved(Date())
        case .both:
            apply(ConflictText.keepBoth(conflict.mine, conflict.theirs), undoable: true)
            editCount += 1
        }
        record("resolve", detail: choice.rawValue)
        Task {
            await writeJournal()
            await flush(reason: "resolve")
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
        }
        applying = false
        let length = (text as NSString).length
        view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
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
        guard ready, locked == nil, !refreshing else { return }
        let url = self.url
        guard let note = await io.run({ Announcement.read(for: url, fresh: true) }),
              note.device != device, !handledAnnouncements.contains(note.sha256),
              note.sha256 != baseFingerprint?.sha256, note.sha256 != uploadedSHA else { return }
        handledAnnouncements.insert(note.sha256)
        record("announce", sha: note.sha256, detail: "\(note.device) uploaded a version this Mac doesn't have (\(reason))")
        guard !unsent, conflict == nil, !saving, !uploading else { return }
        await refresh(announced: note)
    }

    /// Brings down the server's version of the held file (§4.4): hand it back taking the
    /// server's version, evict, download, hold again. About a second (S1b: 0.6-1.3 s).
    private func refresh(announced note: Announcement) async {
        refreshing = true
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
        do {
            let (data, fingerprint) = try await CloudControl.refetch(url, wasPaused: held)
            held = false
            record("refresh", size: data.count, sha: fingerprint.sha256, ms: ms(since: started),
                   detail: fingerprint.sha256 == note.sha256 ? "got \(note.device)'s version" : "the server has another version than the one announced")
            await holdAgain()
            refreshing = false
            if fingerprint.sha256 != baseFingerprint?.sha256 {
                incoming(data, fingerprint: fingerprint, from: note.device, fromServer: true)
            } else {
                uploadedSHA = fingerprint.sha256
            }
        } catch {
            record("refresh", ms: ms(since: started), detail: "failed: \(CloudControl.describe(error))")
            if CloudControl.status(url).paused != true { held = false; await holdAgain() }
            refreshing = false
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
            try await CloudControl.pause(url)
            held = true
        } catch {
            record("pause", detail: "couldn't hold the file again, running unheld: \(CloudControl.describe(error))")
        }
    }

    // MARK: - iCloud state and the file itself

    /// Unheld files: iCloud's own upload state, pushed through the presenter.
    func cloudAttributesChanged() {
        guard ready, !held, conflict == nil, !dirty else { return }
        let status = CloudControl.status(url)
        if status.uploading { state = .uploading(lastSaved) } else if status.uploaded { state = .synced(Date()) }
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
        Task {
            if held { await diskMayHaveChanged() }   // another app on this Mac may have written it
            await checkAnnouncement(reason: "activated")
            await fetchLatest(reason: "activated")
        }
        fetchTimer?.invalidate()
        fetchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkAnnouncement(reason: "every 30 s")
                await self?.fetchLatest(reason: "every 30 s")
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
        let clean = !dirty && conflict == nil && uploadedSHA != nil && uploadedSHA == baseFingerprint?.sha256
        record("quit", ms: ms(since: started), detail: clean ? "everything uploaded; resuming iCloud sync" : "unsent edits; resuming iCloud sync")
        if !clean { await writeJournal() }   // the next launch compares it with the file (§4.8 G)
        do {
            try await CloudControl.resume(url, clean ? .takeServerVersion : .uploadFailingOnConflict)
        } catch {
            // A newer version on the server and unsent edits here: take the server's; the
            // journal (and iCloud's alternate version) keep ours for the next launch's sheet.
            record("resume", detail: "upload refused at quit, taking the server's version; this Mac's text is in the journal: \(CloudControl.describe(error))")
            try? await CloudControl.resume(url, .takeServerVersion)
        }
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
            } catch {
                try? await CloudControl.resume(url, .takeServerVersion)   // local changes become an alternate version
            }
            list.remove(path)
        }
    }

    // MARK: - Helpers

    private func show(_ text: String, for seconds: Double) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func record(_ event: String, size: Int? = nil, sha: String? = nil, ms: Int? = nil, detail: String? = nil) {
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

/// Where the scratch file is, and the M1 safety rule (PRD §8): until M1 has passed on
/// both Macs, nib opens only test files in iCloud Drive/nib-spike/.
enum ScratchLocation {
    static let testFolder = NibPaths.iCloudDrive.appendingPathComponent("nib-spike")

    static var url: URL {
        if let path = UserDefaults.standard.string(forKey: "scratchPath") { return URL(fileURLWithPath: path) }
        return testFolder.appendingPathComponent("scratch-test.md")
    }

    static func refusal(for url: URL) -> String? {
        if UserDefaults.standard.bool(forKey: "allowLiveScratch") { return nil }
        guard url.standardizedFileURL.path.hasPrefix(testFolder.path + "/") else {
            return "NIB OPENS ONLY TEST FILES IN ICLOUD DRIVE/NIB-SPIKE UNTIL M1 HAS PASSED (PRD §8)"
        }
        return nil
    }
}
