// Go to File (PRD KB2, §5.6, A6: ⌘P, and ⌘K for the family) and the command palette (KB3:
// ⇧⌘P), on Blit's palette. Go to File lists the scratch file, the open files, the recent
// ones (newest first), then the text files in Nib's folder, each once; ":12" goes to line 12
// of the file in front, as Sublime's Goto Anything does. The command palette lists every menu
// command that can be chosen now, named as in the menu (W3), with its keys.

import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class PaletteSession: Identifiable {
    enum Kind { case files, commands }

    let kind: Kind
    private(set) var entries: [PaletteEntry] = []
    @ObservationIgnored private var actions: [String: () -> Void] = [:]
    @ObservationIgnored private weak var document: Document?
    /// What was chosen, done once the sheet has gone: a command then goes to the window, not
    /// the sheet.
    @ObservationIgnored private var chosen: (() -> Void)?

    var prompt: String { kind == .files ? "Go to a file, a recent file or the scratch" : "Run a command" }

    init(_ kind: Kind, for document: Document) {
        self.kind = kind
        self.document = document
        switch kind {
        case .files: listFiles()
        case .commands: listCommands()
        }
    }

    func choose(_ entry: PaletteEntry) {
        if entry.id.hasPrefix("line:"), let document {
            let line = String(entry.id.dropFirst(5))
            chosen = { _ = document.goToLine(line) }
        } else {
            chosen = actions[entry.id]
        }
    }

    /// The sheet has gone: what was chosen, a moment later, once the window has its focus back.
    /// Once only, whoever asks first.
    func finish() {
        guard let chosen else { return }
        self.chosen = nil
        let view = document?.editor.textView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let view, view.window?.isKeyWindow == true, !(view.window?.firstResponder is NSTextView) { view.window?.makeFirstResponder(view) }
            chosen()
        }
    }

    /// ":12" or ":12:5": the line (and column) to go to in this file.
    func lineEntry(_ query: String) -> [PaletteEntry] {
        guard kind == .files, query.hasPrefix(":"), let document else { return [] }
        let target = String(query.dropFirst())
        guard !target.isEmpty, target.allSatisfy({ $0.isNumber || $0 == ":" }) else { return [] }
        return [PaletteEntry(id: "line:" + target, name: "Go to Line \(target)", detail: document.url.lastPathComponent,
                             symbol: "arrow.right.to.line", group: "Line")]
    }

    // MARK: Go to File

    @ObservationIgnored private var seen = Set<String>()

    private func add(_ url: URL, group: String, symbol: String, detail: String? = nil) {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard seen.insert(key).inserted else { return }
        entries.append(PaletteEntry(id: key, name: url.lastPathComponent, detail: detail ?? ScratchLocation.place(of: url),
                                    symbol: symbol, group: group))
        actions[key] = { AppDelegate.openFile(url) }
    }

    private func listFiles() {
        add(Documents.scratch.url, group: "Scratch", symbol: "note.text")
        for open in Documents.all where open !== Documents.scratch {
            add(open.url, group: "Open", symbol: open.untitled ? "doc" : "doc.text", detail: open.untitled ? "On this Mac only" : nil)
        }
        for url in RecentFiles.shared.urls { add(url, group: "Recent", symbol: "clock") }
        // Nib's folder, off the main thread: iCloud's file provider answers for it, and it has
        // stopped answering for minutes before. The group comes when the list does.
        let root = ScratchLocation.hasContainer ? ScratchLocation.folder : ScratchLocation.unsignedTestFolder
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.textFiles(in: root) }.value
            for url in found { self?.add(url, group: "Nib Folder", symbol: "folder") }
        }
    }

    /// Text files in `root` and its folders (four deep, 2,000 at most), by name; not hidden
    /// ones, Nib's own `.nib` folder, or pictures, sound, video, PDFs and archives. Names only:
    /// nothing is read.
    nonisolated static func textFiles(in root: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        let notText: [UTType] = [.image, .audiovisualContent, .pdf, .archive, .font, .diskImage, .executable]
        for case let url as URL in walk {
            if walk.level > 4 { walk.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let type = UTType(filenameExtension: url.pathExtension), notText.contains(where: type.conforms(to:)) { continue }
            found.append(url)
            if found.count >= 2_000 { break }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Commands

    /// Every menu command that can be chosen now: the menus as they are with this window in
    /// front, before the sheet takes the focus. Not the palette's own, the window list, Open
    /// Recent (files are Go to File's) or Services.
    private func listCommands() {
        guard let main = NSApp.mainMenu else { return }
        // The app menu (About, Hide, Quit) last: the list starts with File and Edit.
        for top in main.items.dropFirst() + main.items.prefix(1) {
            guard let menu = top.submenu else { continue }
            walk(menu, path: [top.title.isEmpty ? "Nib" : top.title])
        }
    }

    private func walk(_ menu: NSMenu, path: [String]) {
        menu.update()
        for (index, item) in menu.items.enumerated() where !item.isSeparatorItem && !item.isHidden && !item.title.isEmpty {
            if let submenu = item.submenu {
                guard !["Services", "Open Recent"].contains(item.title) else { continue }
                walk(submenu, path: path + [item.title])
                continue
            }
            guard item.isEnabled, item.action != nil, item.action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                  !["Go to File…", "Command Palette…"].contains(item.title) else { continue }
            let id = (path + [item.title, String(index)]).joined(separator: "\u{1F}")
            entries.append(PaletteEntry(id: id, name: item.title, detail: path.joined(separator: " › "), symbol: "command",
                                        group: "", shortcut: Self.keys(of: item)))
            // Found again when it's done, in the menus as they are then (SwiftUI may have made
            // them afresh meanwhile).
            actions[id] = { Self.perform(path: path, title: item.title) }
        }
    }

    private static func perform(path: [String], title: String) {
        var menu = NSApp.mainMenu
        for name in path {
            menu = menu?.items.first { ($0.title.isEmpty ? "Nib" : $0.title) == name }?.submenu
        }
        guard let menu, let item = menu.items.first(where: { $0.title == title }) else { NSSound.beep(); return }
        menu.update()
        guard item.isEnabled else { NSSound.beep(); return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    /// A menu item's keys as the menu shows them: ⌃⌥⇧⌘, then the key.
    static func keys(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var mask = item.keyEquivalentModifierMask
        if key.count == 1, let c = key.first, c.isUppercase { mask.insert(.shift) }   // "D" is ⇧D
        let modifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { mask.contains($0.0) }.map(\.1).joined()
        func function(_ key: Int) -> Character { Character(UnicodeScalar(UInt32(key))!) }
        let names: [Character: String] = [
            "\r": "↩", "\t": "⇥", " ": "Space", "\u{1B}": "⎋", "\u{8}": "⌫", "\u{7F}": "⌫",
            function(NSUpArrowFunctionKey): "↑", function(NSDownArrowFunctionKey): "↓",
            function(NSLeftArrowFunctionKey): "←", function(NSRightArrowFunctionKey): "→", function(NSDeleteFunctionKey): "⌦",
        ]
        let name = key.count == 1 ? (names[key.first!] ?? key.uppercased()) : key.uppercased()
        return modifiers + name
    }
}
