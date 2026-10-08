// The menu bar extra (PRD §5.7, AP3, V11, A10): Nib's pixel nib over a line, still when idle;
// the line's dashes march once an upload has been pending for more than 3 s (V7: 0.16 s a
// step), and the muted-red ✕ sits beside it while a conflict or a problem needs a look. The
// panel is Blit's 320 pt column: a HUD card for the scratch file (its state, when it was saved
// and uploaded, the other Mac's last version), then native rows: Show Scratch, Clean
// Clipboard, Append Clipboard to Scratch, recent files, Settings…, Quit Nib. Optional
// (Settings › General), on by default, as in Blit (T10).
//
// AppKit's own status item and a panel of Nib's, not SwiftUI's MenuBarExtra: on macOS 27 that
// never took the item out when turned off (its `isInserted` going false did nothing), and
// showed only the first of its label's images (the ✕ beside the nib never appeared).

import NibSync
import NibText
import SwiftUI

enum NibMark {
    /// The nib, 9 cells wide, over a blank row (§5.7's first draft).
    static let nib = ["#########", "#########", "###...###", "###...###", ".###.###.", "..##.##..", "...#.#...", "....#....", "........."]

    /// The line under it: solid, or dashes one step further right each frame.
    static func line(frame: Int?) -> String {
        guard let frame else { return "#########" }
        return String((0..<9).map { x in (x - frame % 3 + 3) % 3 == 2 ? Character(".") : Character("#") })
    }

    static func rows(frame: Int?) -> [String] { nib + [line(frame: frame)] }
    @MainActor static var width: CGFloat { 9 * MenuBarMark.cell }

    /// The item's one image. The menu bar takes only a label's first image (macOS 27: a ✕
    /// beside the nib as a second image never showed), so with the ✕ it's one picture: not a
    /// template, since the ✕ keeps its red, and the nib in the label color, which takes the
    /// menu bar's own appearance when it's drawn. Without it, a template, as Blit's is.
    @MainActor static func image(frame: Int?, failure: Bool) -> NSImage {
        let rows = rows(frame: frame)
        guard failure else { return MenuBarMark.image(rows, width: width) }
        let cell = MenuBarMark.cell, mark = MenuBarMark.failure
        let size = NSSize(width: width + 2 + mark.size.width, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            let top = ((18 - CGFloat(rows.count) * cell) / 2).rounded()
            NSColor.labelColor.setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: top + CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            mark.draw(in: NSRect(x: width + 2, y: 0, width: mark.size.width, height: 18))
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// What the menu bar item says, from the open documents.
@MainActor
enum MenuBarState {
    /// Saved here, iCloud not yet told or still taking it.
    static func pending(_ document: Document) -> Bool {
        switch document.state {
        case .saved, .uploading: !document.untitled
        default: false
        }
    }

    static func needsLook(_ document: Document) -> Bool {
        if !document.blocks.isEmpty { return true }
        if case .problem = document.state { return true }
        return false
    }

    /// What a file needs a look for, in the HUD's words: "CONFLICT · 2 PLACES", "IN THE TRASH".
    static func look(_ document: Document) -> String? {
        if !document.blocks.isEmpty { return "CONFLICT · \(document.blocks.count) PLACE\(document.blocks.count == 1 ? "" : "S")" }
        if case .problem(let why) = document.state { return SyncHUD.problemWord(why) }
        return nil
    }

    /// The open files besides the scratch file that need a look: the ✕ lit for them, while the
    /// panel and the tooltip spoke only of the scratch file (the QA review's F11).
    static func othersNeedingLook() -> [Document] {
        Documents.all.filter { $0 !== Documents.scratch && needsLook($0) }
    }

    /// The tooltip's and VoiceOver's words for them: "NOTES.MD NEEDS A LOOK (CONFLICT · 2 PLACES)".
    static func othersLine(_ others: [Document]) -> String? {
        guard let first = others.first else { return nil }
        if others.count > 1 { return "\(others.count) OTHER FILES NEED A LOOK" }
        return "\(first.url.lastPathComponent.uppercased()) NEEDS A LOOK (\(look(first) ?? "SEE ITS WINDOW"))"
    }

    /// The scratch file's card, in the HUD's words (W5): its name, its state, when it was
    /// saved and uploaded, and the other Mac's last version ("—" where there's none yet).
    static func card(_ document: Document) -> [String] {
        let uploaded = document.uploadedAt.map(SyncState.stamp) ?? (document.uploadedBeforeOpening ? "BEFORE OPENING" : "—")
        var lines = [document.url.lastPathComponent.uppercased(), document.statusLine,
                     "SAVED \(document.savedAt.map(SyncState.stamp) ?? "—") · UPLOADED \(uploaded)"]
        if !document.blocks.isEmpty {
            lines.append("✕ CONFLICT · \(document.blocks.count) PLACE\(document.blocks.count == 1 ? "" : "S") · BOTH VERSIONS IN THE TEXT")
        }
        // Each other Mac: what its receipt says it has (SY14), and its last upload (its note).
        for other in document.otherMacs { lines.append(other.line) }   // the strip's and the HUD's words (F41)
        if let other = document.otherMac {
            lines.append("\(other.device.uppercased()) · LAST UPLOAD \(SyncState.stamp(other.time))")
        } else if document.otherMacs.isEmpty {
            lines.append("NO OTHER MAC YET")
        }
        return lines
    }
}

/// The status item and its panel, for as long as Settings › General says so.
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private(set) var item: NSStatusItem?
    private(set) var panel: NSPanel?
    private var frame = 0
    private var ticker: Timer?
    private var outside: Any?

    var button: NSStatusBarButton? { item?.button }

    func start() {
        apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        track()
    }

    /// System Settings › Accessibility › Display › Reduce Motion (A16). The scenarios can say
    /// so with -NibReduceMotion.
    static var reduceMotion: Bool {
        #if DEBUG
        if NibDefaults.store.object(forKey: "NibReduceMotion") != nil { return NibDefaults.store.bool(forKey: "NibReduceMotion") }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// In the menu bar or not, as Settings › General says (on unless turned off; off in the
    /// test harness's Nib, whose item would stand beside the user's, but for `menubar`).
    /// Settings › General's "Show Nib in the menu bar": on unless turned off, but not for a test
    /// run's Nib (the `menubar` scenario's apart).
    static var enabledInSettings: Bool {
        let defaults = NibDefaults.store
        let standard = !NibPaths.isScenario || NibDefaults.scenario == "menubar"
        return defaults.object(forKey: "showMenuBarExtra") == nil ? standard : defaults.bool(forKey: "showMenuBarExtra")
    }

    func apply() {
        defer { DockIcon.apply() }   // hidden only while this is shown (AP6)
        let on = Self.enabledInSettings
        if on, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
            self.item = item
            refresh()
        } else if !on, let item {
            closePanel()
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            ticker?.invalidate()
            ticker = nil
        }
    }

    /// The documents' states, watched: the item drawn again when one changes. (A file opened
    /// since is watched from the next change on; Documents tells this when files open too.)
    private func track() {
        withObservationTracking {
            for document in Documents.all { _ = document.state; _ = document.blocks; _ = document.otherMacs }
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.track()
                }
            }
        }
    }

    /// An upload more than 3 s past when it was due: counted from the save, typing's ordinary
    /// pause marched for a second or two (the QA review's F43).
    static func overdue(_ documents: [Document]) -> Bool {
        documents.contains { MenuBarState.pending($0) && ($0.uploadPendingSince.map { Date().timeIntervalSince($0) > 3 } ?? false) }
    }

    /// The image, the words for VoiceOver, and the march: still, then once an upload is 3 s past
    /// due, a step every 0.16 s until it's taken.
    func refresh() {
        guard let button else { return }
        let documents = Documents.all
        let pending = documents.contains(where: MenuBarState.pending)
        let look = documents.contains(where: MenuBarState.needsLook)
        let marching = Self.overdue(documents)
        // With Reduce Motion (A16, AX3) the line doesn't march: it stays in dashes while it waits.
        button.image = NibMark.image(frame: marching ? (Self.reduceMotion ? 0 : frame) : nil, failure: look)
        // The scratch file's line says its own problem; the others are named (F11).
        let others = MenuBarState.othersLine(MenuBarState.othersNeedingLook())
        let spoken = "Nib, " + SyncState.midSentence(Documents.scratch.statusSpoken) + (others.map { "; " + SyncState.midSentence(Spoken.sentence($0)) } ?? "")
        button.setAccessibilityLabel(spoken)
        button.toolTip = "Nib · " + Documents.scratch.statusLine + (others.map { " · " + $0 } ?? "")
        if pending, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if !Self.reduceMotion, Self.overdue(Documents.all) { self.frame = (self.frame + 1) % 3 }
                    self.refresh()
                }
            }
        } else if !pending {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: The panel

    @objc func toggle(_ sender: Any?) {
        if panel?.isVisible == true { closePanel() } else { openPanel() }
    }

    func openPanel() {
        guard let button, let place = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) else { return }
        let host = NSHostingView(rootView: NibMenuBarPanel(close: { [weak self] in self?.closePanel() }))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = self.panel ?? PanelWindow(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        let backing = NSVisualEffectView(frame: host.frame)
        backing.material = .menu
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 10
        backing.layer?.masksToBounds = true
        backing.addSubview(host)
        panel.contentView = backing
        let screen = button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(screen.minX + 4, place.midX - host.frame.width / 2), screen.maxX - host.frame.width - 4)
        panel.setFrame(NSRect(x: x, y: place.minY - host.frame.height - 6, width: host.frame.width, height: host.frame.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        button.highlight(true)
        // A click anywhere else closes it, as a menu does.
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        button?.highlight(false)
        if let outside { NSEvent.removeMonitor(outside) }
        outside = nil
    }

    /// Takes key focus without making Nib the active app, and closes on Escape or on losing it.
    private final class PanelWindow: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { MenuBarController.shared.closePanel() }
        override func resignKey() {
            super.resignKey()
            MenuBarController.shared.closePanel()
        }
    }
}

struct NibMenuBarPanel: View {
    /// Closes the panel: after an action that leaves it (a window, Settings).
    var close: () -> Void = {}
    @State private var message: String?
    /// The row lit, by ↑ and ↓ or the pointer: Return or Space chooses it, as in a menu (the QA
    /// review's F82: the panel took no key but Escape).
    @State private var lit: Int?
    @FocusState private var focused: Bool

    /// A row of the panel: what it says, and what it does.
    struct Row {
        let title: String
        var keys: String?
        var detail: String?
        /// What VoiceOver says, when the title and detail as written don't read well.
        var spoken: String?
        var failure = false
        let action: () -> Void
    }

    /// The rows by group, in order: the other files the ✕ is lit for, the three commands, Recent,
    /// then Settings and Quit.
    private func groups() -> [[Row]] {
        // The other open files the ✕ is lit for, each opening its window (F11).
        let others = MenuBarState.othersNeedingLook().map { document in
            let look = MenuBarState.look(document) ?? ""
            return Row(title: document.url.lastPathComponent, detail: "✕ " + look,
                       spoken: "\(document.url.lastPathComponent), \(Spoken.sentence(look).lowercased())", failure: true) {
                close()
                NSApp.activate()
                AppDelegate.openFile(document.url)
            }
        }
        let shortcuts = GlobalShortcuts.shared
        let commands = [
            Row(title: "Show Scratch", keys: shortcuts.shortcut(.showScratch)?.description) { close(); AppDelegate.showScratch() },
            Row(title: "Clean Clipboard", keys: shortcuts.shortcut(.cleanClipboard)?.description) { message = Clipboard.cleanInPlace() },
            Row(title: "Append Clipboard to Scratch", keys: shortcuts.shortcut(.appendClipboard)?.description) { message = Clipboard.appendToScratch() },
        ]
        // Not the scratch file (Show Scratch is above), nor files gone since.
        let scratch = Documents.scratch.url.standardizedFileURL.path
        let recent = RecentFiles.shared.urls.filter {
            $0.standardizedFileURL.path != scratch && FileManager.default.fileExists(atPath: $0.path)
        }.prefix(5).map { url in
            Row(title: url.lastPathComponent, detail: ScratchLocation.place(of: url)) {
                close()
                NSApp.activate()
                AppDelegate.openFile(url)
            }
        }
        let app = [
            Row(title: "Settings…", keys: "⌘,") { close(); AppDelegate.openSettings() },
            Row(title: "Quit Nib", keys: "⌘Q") { NSApp.terminate(nil) },
        ]
        return [others, commands, Array(recent), app]
    }

    var body: some View {
        let groups = groups()
        let rows = groups.flatMap { $0 }
        let starts = groups.indices.map { index in groups[..<index].reduce(0) { $0 + $1.count } }
        VStack(alignment: .leading, spacing: 10) {
            ScratchCard(document: Documents.scratch)
            if !groups[0].isEmpty { section(groups[0], from: starts[0]) }
            if let message {
                hudText(message, glyphSize: 9)
                    .font(HUDFont.terminal(15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Spoken.sentence(message))   // F61
            }
            Divider()
            section(groups[1], from: starts[1])
            if !groups[2].isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                    section(groups[2], from: starts[2])
                }
            }
            Divider()
            section(groups[3], from: starts[3])
        }
        .padding(12)
        .frame(width: 320)
        // The keys, as a menu takes them: ↓ and ↑ round the rows, Return or Space the one lit.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { lit = lit.map { ($0 + 1) % rows.count } ?? 0; return .handled }
        .onKeyPress(.upArrow) { lit = lit.map { ($0 + rows.count - 1) % rows.count } ?? rows.count - 1; return .handled }
        .onKeyPress(.return) { choose(rows) }
        .onKeyPress(.space) { choose(rows) }
        // What the clipboard commands did, said as it shows (the QA review's F62: only drawn).
        .onChange(of: message) { _, said in if let said { Announce.hud(said) } }
        #if DEBUG
        .onChange(of: lit) { _, row in Self.litTitle = row.flatMap { rows.indices.contains($0) ? rows[$0].title : nil } }
        #endif
    }

    private func choose(_ rows: [Row]) -> KeyPress.Result {
        guard let lit, rows.indices.contains(lit) else { return .ignored }
        rows[lit].action()
        return .handled
    }

    private func section(_ rows: [Row], from first: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                PanelRow(row.title, keys: row.keys, detail: row.detail, spoken: row.spoken, lit: lit == first + offset,
                         hover: { inside in
                             if inside { lit = first + offset } else if lit == first + offset { lit = nil }
                         }, action: row.action)
                    .foregroundStyle(row.failure ? AnyShapeStyle(HUDColor.failureText) : AnyShapeStyle(.primary))
            }
        }
    }

    #if DEBUG
    /// The lit row's title, for the `menubar` scenario.
    static var litTitle: String?
    #endif
}

/// The scratch file's HUD card: Blit's panel card, with Nib's facts.
struct ScratchCard: View {
    let document: Document

    var body: some View {
        let lines = MenuBarState.card(document)
        VStack(alignment: .leading, spacing: 4) {
            Text(lines[0]).font(HUDFont.terminal(17)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                if let tag = document.state.tag {
                    hudText(tag, glyphSize: 9)
                        .font(HUDFont.label(9))
                        .foregroundStyle(HUDColor.onFailure)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HUDColor.failure)
                        .fixedSize()
                }
                hudText(lines[1], glyphSize: 11)
                    .font(HUDFont.terminal(16))
                    .foregroundStyle(document.state.tag != nil ? HUDColor.failureText : document.state.isDim ? HUDColor.dim : HUDColor.bright)
                    .lineLimit(2)
            }
            ForEach(lines.dropFirst(2), id: \.self) { line in
                hudText(line, glyphSize: 9)
                    .font(HUDFont.terminal(15))
                    .foregroundStyle(line.hasPrefix("✕") ? HUDColor.failureText : HUDColor.dim)
                    .lineLimit(2)
            }
        }
        .foregroundStyle(HUDColor.bright)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(document.url.lastPathComponent), \(document.statusSpoken). " + lines.dropFirst(2).map(Spoken.sentence).joined(separator: ". "))
    }
}

/// A native row in the panel: its title, and its keys or where it is on the right; lit by the
/// pointer or the keys, one at a time (the panel keeps which).
struct PanelRow: View {
    let title: String
    var keys: String?
    var detail: String?
    /// What VoiceOver says, when the title and detail as written don't read well.
    var spoken: String?
    var lit = false
    var hover: (Bool) -> Void = { _ in }
    let action: () -> Void

    init(_ title: String, keys: String? = nil, detail: String? = nil, spoken: String? = nil, lit: Bool = false,
         hover: @escaping (Bool) -> Void = { _ in }, action: @escaping () -> Void) {
        self.title = title; self.keys = keys; self.detail = detail; self.spoken = spoken
        self.lit = lit; self.hover = hover; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                if let keys { Text(keys).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(lit ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover(perform: hover)
        // The detail too: Recent rows with the same name sounded the same (F82).
        .accessibilityLabel(spoken ?? [title, detail, keys.map(Spoken.sentence)].compactMap { $0 }.joined(separator: ", "))   // keys as words (F61)
        .accessibilityAddTraits(lit ? .isSelected : [])
    }
}
