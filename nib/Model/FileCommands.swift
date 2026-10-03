// Duplicate, Rename… and Move To… (PRD ED4, W3: Apple's autosave model, in the File menu).
// Duplicate makes an untitled buffer with the same text, "notes copy.md" (ED3), for Save… to
// put somewhere. Rename and Move To close the file first, as its window closing would (saved,
// uploaded, handed back to iCloud, §4.3), so a held file is never moved; then a coordinated
// move, the file's History, caret, syntax and known duplicates carried to the new path, and
// the file opened again there. An untitled buffer is renamed as a new buffer of the same text,
// its caret and History carried as a file's are; Move To… on one is Save…. The scratch file
// isn't renamed or moved (Settings › General picks another). Under the safety rule (§8),
// nothing goes outside the test folders.

import AppKit
import NibSync

@MainActor
enum FileCommands {
    /// File › Duplicate (⇧⌘S).
    static func duplicate(_ document: Document) {
        guard let url = Untitled.create(text: document.editor.textView.string, name: copyName(document.url.lastPathComponent)) else {
            document.show("COULDN'T MAKE A COPY · NIB'S UNTITLED FOLDER ISN'T WRITABLE", for: 8)
            return
        }
        AppDelegate.openFile(url)
    }

    /// "notes.md" → "notes copy.md", as Finder and Apple's apps name a copy.
    static func copyName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
    }

    static func canMove(_ document: Document?) -> Bool {
        guard let document else { return false }
        return document !== Documents.scratch && document.locked == nil
    }

    // MARK: Asking

    /// File › Rename…: the name in a sheet, its base selected as Finder selects it.
    static func askRename(_ document: Document) {
        guard canMove(document), let window = document.editor.textView.window else { return }
        let name = document.url.lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Rename “\(name)”"
        alert.informativeText = document.untitled ? "An untitled buffer's name is the one Save… suggests." : "In \(ScratchLocation.place(of: document.url))."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let wanted = field.stringValue.trimmingCharacters(in: .whitespaces)
            Task { await rename(document, to: wanted) }
        }
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: ((name as NSString).deletingPathExtension as NSString).length)
        }
    }

    /// File › Move To…: a folder, in a sheet.
    static func askMove(_ document: Document) {
        guard canMove(document) else { return }
        if document.untitled { Untitled.saveAs(document); return }
        guard let window = document.editor.textView.window else { return }
        let panel = NSOpenPanel()
        panel.message = "Move “\(document.url.lastPathComponent)” to:"
        panel.prompt = "Move"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await move(document, to: folder.appendingPathComponent(document.url.lastPathComponent)) }
        }
    }

    // MARK: Doing

    /// A new name in the same folder. Nil when done; otherwise why not, in the HUD's words (shown).
    @discardableResult
    static func rename(_ document: Document, to name: String) async -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            return refuse(document, "“\(name.uppercased())” CAN'T BE A FILE NAME · NOTHING RENAMED")
        }
        return await move(document, to: document.url.deletingLastPathComponent().appendingPathComponent(name))
    }

    /// The file at `target`, closed and opened again there. Nil when done; otherwise why not.
    @discardableResult
    static func move(_ document: Document, to target: URL) async -> String? {
        let old = document.url
        guard canMove(document) else { return refuse(document, "THE SCRATCH FILE STAYS WHERE IT IS · SETTINGS › GENERAL PICKS ANOTHER") }
        guard target.standardizedFileURL.path != old.standardizedFileURL.path else { return nil }
        // "Notes.md" to "notes.md" is the same file on a Mac's disk: a new name, not a clash.
        let caseOnly = target.path.lowercased() == old.path.lowercased()
        if document.untitled { return await renameUntitled(document, to: target.lastPathComponent) }
        if ScratchLocation.refusal(for: target) != nil {
            return refuse(document, "NOT MOVED · NIB OPENS ONLY TEST FILES (ICLOUD DRIVE › NIB › TEST) UNTIL M1 HAS PASSED (PRD §8)")
        }
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
            return refuse(document, "“\(target.lastPathComponent.uppercased())” IS ALREADY THERE · NOTHING MOVED")
        }
        if let open = Documents.existing(for: target), open !== document {   // (by case alone, it finds this one)
            return refuse(document, "“\(target.lastPathComponent.uppercased())” IS OPEN IN NIB · NOTHING MOVED")
        }

        // Everything in the file and in iCloud first: then the move leaves nothing behind in the
        // journal under the old name.
        await document.saveNow()
        for _ in 0..<100 where document.unsent { try? await Task.sleep(for: .milliseconds(100)) }
        guard !document.unsent else { return refuse(document, "NOT MOVED · ICLOUD HASN'T TAKEN THE LAST CHANGES YET · TRY AGAIN IN A MOMENT") }

        let window = document.editor.textView.window
        document.editor.textView.isEditable = false
        await Documents.close(document)   // saved, uploaded, handed back: nothing holds it now
        if let closed = ClosedItems.shared.items.first(where: { $0.path == old.path }) { ClosedItems.shared.forget(closed) }
        window?.close()
        do {
            try await CloudControl.within(20) { try coordinatedMove(old, to: target, caseOnly: caseOnly) }
        } catch {
            AppDelegate.openFile(old)   // as it was
            let why = "COULDN'T MOVE “\(old.lastPathComponent.uppercased())” · \(error.localizedDescription.uppercased())"
            Toast.show(why)
            return why
        }
        carrySettings(from: old, to: target)
        AppDelegate.openFile(target)
        RecentFiles.shared.remove(old)
        return nil
    }

    private static func refuse(_ document: Document, _ why: String) -> String {
        document.show(why, for: 10)
        return why
    }

    /// An untitled buffer by another name: a new one with the same text, caret and History, this one let go.
    private static func renameUntitled(_ document: Document, to name: String) async -> String? {
        guard !Untitled.all().contains(where: { $0.lastPathComponent == name }) else {
            return refuse(document, "AN UNTITLED BUFFER IS ALREADY CALLED “\(name.uppercased())” · NOTHING RENAMED")
        }
        guard let url = Untitled.create(text: document.editor.textView.string, name: name) else {
            return refuse(document, "COULDN'T RENAME IT · NIB'S UNTITLED FOLDER ISN'T WRITABLE")
        }
        await Untitled.handOver(document, to: url)
        return nil
    }

    /// Off the main thread (SY8), coordinated so that anything presenting the file hears of it.
    nonisolated static func coordinatedMove(_ from: URL, to: URL, caseOnly: Bool) throws {
        var coordination: NSError?, failure: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing, error: &coordination) { source, destination in
            do {
                coordinator.item(at: source, willMoveTo: destination)
                if caseOnly {
                    // Through another name: a move to what the disk calls the same name fails.
                    let between = source.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)-\(source.lastPathComponent)")
                    try FileManager.default.moveItem(at: source, to: between)
                    try FileManager.default.moveItem(at: between, to: destination)
                } else {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
                coordinator.item(at: source, didMoveTo: destination)
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
    }

    /// What Nib keeps for a file by its path: its History (§4.9), caret (SC3), syntax (HL1) and
    /// the duplicates it has seen (§4.6 C). History is merged into the new path's when that has
    /// some (it was left behind, never thinned again, until 2026-10-03). Without `syntax`, the old
    /// path's pick is dropped, not carried: an untitled buffer saved or renamed takes its syntax
    /// from its new name, as before, not from ⌘N's Markdown.
    static func carrySettings(from old: URL, to new: URL, syntax: Bool = true) {
        let defaults = NibDefaults.store
        for prefix in ["selection:", "syntax:", "siblings:"] {
            if let value = defaults.object(forKey: prefix + old.path) {
                if syntax || prefix != "syntax:" { defaults.set(value, forKey: prefix + new.path) }
                defaults.removeObject(forKey: prefix + old.path)
            }
        }
        // Never into the History of a file open in Nib: its document writes there under a lock of
        // its own, which ours wouldn't share.
        guard Documents.existing(for: new) == nil else { return }
        let root = NibPaths.support.appendingPathComponent("History")
        try? History(root: root, path: old.path).move(to: History(root: root, path: new.path))
    }
}
