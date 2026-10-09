// The sync HUD (PRD §5.3, SY16): the strip's sync state, clicked, or View › Show Sync Details
// (⇧⌘Y), opens upward over the text into Blit's boxed HUD: the file, iCloud's state, the Macs
// that have it (their receipts, SY14), and the file's last six Sync Log lines, with a WARNING
// panel at the log's height while conflict blocks are in the text. It switches on and off like
// Blit's CRT (V7), and fades under Reduce Motion (A16). Escape, its header or another click on
// the strip closes it; it never opens by itself (A2). The same rows every time, with "—" where
// one doesn't apply, so its height never changes (V10).

import Combine
import NibSync
import NibText
import SwiftUI

struct SyncHUD: View {
    let document: Document
    @State private var log: [SyncEvent] = []
    @State private var appended = 0

    static let logLines = 6
    static let lineHeight: CGFloat = 18
    static let macRows = 4
    private static let syncLog = SyncLog(url: NibPaths.support.appendingPathComponent("sync.jsonl"))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                filePanel.frame(maxWidth: .infinity)
                iCloudPanel.frame(maxWidth: .infinity)
                macsPanel.frame(width: 230)
            }
            .fixedSize(horizontal: false, vertical: true)
            // The log sets this row's height, and the WARNING panel takes exactly that height (an
            // overlay), so a conflict never makes the HUD taller (Blit at 1f79dd0).
            HStack(alignment: .top, spacing: 10) {
                logPanel.frame(maxWidth: .infinity)
                if warning != nil { Color.clear.frame(width: 260) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if let warning { warningPanel(warning).frame(width: 260).frame(maxHeight: .infinity) }
            }
        }
        .foregroundStyle(HUDColor.bright)
        .padding(14)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())   // clicks on it don't reach the text under it
        // The file's lines: read as it opens, and again a moment after each new line in the log
        // (a burst of them read once).
        .task(id: appended) {
            if appended > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled else { return }
            let path = document.url.path, syncLog = Self.syncLog, limit = Self.logLines
            let lines = await Task.detached(priority: .utility) { syncLog.recent(path: path, limit: limit) }.value
            if !Task.isCancelled { log = lines }
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncLog.didAppend).receive(on: DispatchQueue.main)) { _ in appended += 1 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sync details for \(document.url.lastPathComponent)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { document.syncDetailsShown = false } label: {
                hudText("▼ SYNC · \(document.url.lastPathComponent.uppercased())", glyphSize: 9)
                    .font(HUDFont.label())
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Hide the sync details (Escape)")
            .accessibilityLabel("Hide the sync details")
            Spacer(minLength: 8)
            Text("RUNE://SYNC").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
                .accessibilityHidden(true)
        }
    }

    // MARK: Panels

    private var filePanel: some View {
        let lines = document.editor.lineIndex.lineCount
        return HUDPanel("File") {
            Group {
                Text(document.url.lastPathComponent.uppercased()).lineLimit(1).truncationMode(.middle)
                Text(document.untitled ? "ON THIS MAC ONLY" : ScratchLocation.place(of: document.url).uppercased())
                    .foregroundStyle(HUDColor.dim).lineLimit(1).truncationMode(.head)
                Text("\(Self.bytes(document.fileBytes)) · \(lines.formatted()) LINE\(lines == 1 ? "" : "S")").lineLimit(1)
                Text("SHA256 \(document.versionSHA.map { String($0.prefix(12)).uppercased() + "…" } ?? "—")")
                    .foregroundStyle(HUDColor.dim).lineLimit(1)
                    .help(document.versionSHA.map { "The version this text comes from: \($0)" } ?? "")
                // Changes since the last commit (ED12), in a git repository.
                if let git = document.git.hudLine {
                    Text(git).foregroundStyle(HUDColor.dim).lineLimit(1).truncationMode(.middle)
                        .help("Lines that differ from the last commit, as the gutter marks them")
                }
            }
            .font(HUDFont.terminal(18))
        }
        .accessibilityElement(children: .combine)
    }

    private var iCloudPanel: some View {
        HUDPanel(document.untitled || !document.inICloud ? "This Mac" : "iCloud") {
            HUDRow("STATE", Self.stateWord(document))
                .foregroundStyle(document.state.isProblem ? HUDColor.failureText : HUDColor.bright)
            // "—" until there's a time to show (F13: both said the time it opened).
            HUDRow("SAVED", document.savedAt.map(SyncState.stamp) ?? "—")
            HUDRow("UPLOADED", document.untitled ? "NEVER" : !document.inICloud ? "NOT IN ICLOUD"
                   : document.uploadedAt.map(SyncState.stamp) ?? (document.uploadedBeforeOpening ? "BEFORE OPENING" : "—"))
            HUDRow("ON DISK", Self.onDisk(document))
        }
        .accessibilityElement(children: .combine)
    }

    private var macsPanel: some View {
        let rows = macs
        return HUDPanel("Macs") {
            ForEach(0..<Self.macRows, id: \.self) { slot in
                if slot < rows.count {
                    HUDRow(rows[slot].name, rows[slot].value)
                } else {
                    Text("—").font(HUDFont.terminal(18)).foregroundStyle(HUDColor.dim).accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// This Mac, then each other Mac's receipt for the file: "✓ 10:42:31" (it has this version),
    /// "▼ NEWER · 10:42" (one this Mac hasn't seen), "OLDER · 10:40" (it hasn't got this one yet).
    private var macs: [(name: String, value: String)] {
        var rows = [(name: document.device.uppercased(), value: "THIS MAC")]
        if document.untitled { return rows }
        let others = document.otherMacs.sorted { $0.device < $1.device }
        for other in others.prefix(Self.macRows - 1) {
            rows.append((other.device.uppercased(), other.short))   // the strip's and the panel's words (F41)
        }
        if others.count > Self.macRows - 1 {   // the last row says how many more
            rows[Self.macRows - 1] = (name: "+\(others.count - (Self.macRows - 2)) MORE", value: "")
        }
        return rows
    }

    private var logPanel: some View {
        let lines = Array(log.suffix(Self.logLines))
        return HUDPanel("Log") {
            ForEach(0..<Self.logLines, id: \.self) { slot in
                Group {
                    if slot < lines.count {
                        let event = lines[slot]
                        hudText("\(SyncState.clock.string(from: event.time)) \(Self.line(event))", glyphSize: 11)
                            .foregroundStyle(event.failed || event.event == "conflict" ? HUDColor.failureText : HUDColor.bright)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(event.detail ?? "")
                    } else {
                        Text("—").foregroundStyle(HUDColor.dim).accessibilityHidden(true)   // an empty slot (F39)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Self.lineHeight, maxHeight: Self.lineHeight, alignment: .leading)
            }
        }
        .font(HUDFont.terminal(16))
        .accessibilityElement(children: .combine)
    }

    // MARK: WARNING (W1)

    struct Warning: Equatable {
        var count: Int
        var lines: ClosedRange<Int>
    }

    /// Unresolved conflict blocks: how many, and the first one's lines.
    private var warning: Warning? {
        guard let first = document.blocks.first else { return nil }
        let index = document.editor.lineIndex
        let start = index.line(at: first.range.location)
        let end = index.line(at: max(first.range.location, NSMaxRange(first.range) - 1))
        return Warning(count: document.blocks.count, lines: start...max(start, end))
    }

    /// "LINES 14-16", or with more than one block, "FIRST AT LINES 14-16": "2 CONFLICTS · LINES
    /// 14-16" read as if both were there (the QA review's F68).
    static func whereWords(_ warning: Warning) -> String {
        let lines = warning.lines.count == 1 ? "LINE \(warning.lines.lowerBound)" : "LINES \(warning.lines.lowerBound)-\(warning.lines.upperBound)"
        return warning.count == 1 ? lines : "FIRST AT " + lines
    }

    private func warningPanel(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                hudText("✕ WARNING", glyphSize: 9).font(HUDFont.label())
                Group {
                    Text("\(warning.count) CONFLICT\(warning.count == 1 ? "" : "S")")
                    Text(Self.whereWords(warning))
                    Text("BOTH SIDES KEPT IN THE FILE")
                }
                .font(HUDFont.terminal(18))
            }
            // Its words one element, the button another: combined, the button's name was hidden (F68).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Warning: \(Spoken.sentence("\(warning.count) CONFLICT\(warning.count == 1 ? "" : "S") · \(Self.whereWords(warning))")), both sides kept in the file")
            Spacer(minLength: 0)
            Button { document.openMerge() } label: {   // as ⌥⌘R does (F52)
                Text("MERGE VIEW ⌥⌘R").font(HUDFont.label()).underline()
            }
            .buttonStyle(.plain)
            .help("Open the merge view (⌥⌘R)")
            .accessibilityLabel("Merge view, Option-Command-R")
            .disabled(document.merge != nil)
        }
        .foregroundStyle(HUDColor.onFailure)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HUDColor.failure)
        .accessibilityElement(children: .contain)
    }

    // MARK: Words

    /// The strip's state without its time: "▼ NEWER ON AIR" while the strip says so, not
    /// "✓ SYNCED" beside it (F41).
    static func stateWord(_ document: Document) -> String {
        if case .synced = document.state, let newer = document.otherMacs.first(where: { $0.delivery == .newer }) {
            return "▼ NEWER ON \(newer.device.uppercased())"
        }
        return stateWord(document.state)
    }

    /// The state's glyph and words, without its time (the rows have the times).
    static func stateWord(_ state: SyncState) -> String {
        switch state {
        case .opening: "· OPENING"
        case .notDownloaded: "◐ DOWNLOADING"
        case .offline(_, let slow): slow ? "◐ NOT HERE YET" : "◐ OFFLINE"
        case .editing: "· EDITING"
        case .saved: "= SAVED LOCALLY"
        case .savedHere: "✓ SAVED"
        case .uploading: "▲ UPLOADING"
        case .local: "= ON THIS MAC ONLY"   // as the strip says it (F41)
        case .synced: "✓ SYNCED"
        case .waiting(let why): "‖ " + fact(why)
        case .problem(let why): "✕ " + problemWord(why)
        }
    }

    /// A problem's first fact, short enough for its row: "✕ PROBLEM" said nothing of what (the QA
    /// review's F12). The strip and the tooltip have the whole line.
    static func problemWord(_ why: String) -> String {
        if why.hasPrefix("MOVED TO THE TRASH") { return "IN THE TRASH" }
        if why.hasPrefix("DELETED") { return "DELETED" }
        if why == Document.diskFull { return "DISK FULL" }
        if why.hasPrefix("ICLOUD STORAGE IS FULL") { return "ICLOUD FULL" }
        if why.hasPrefix("ICLOUD DRIVE IS OFF") { return "ICLOUD DRIVE OFF" }
        if why.hasPrefix("COULDN'T WRITE THE RECOVERY JOURNAL") { return "NO JOURNAL" }
        if why.hasPrefix("COULDN'T SAVE") || why.hasPrefix("COULDN'T RESTORE") { return "NOT SAVED" }
        if why.hasPrefix("COULDN'T READ") || why.hasPrefix("COULDN'T CREATE") { return "NOT OPENED" }
        if why.hasPrefix("RUNE'S ICLOUD FOLDER ISN'T AVAILABLE") { return "NO ICLOUD FOLDER" }
        if why.contains(" MOVED ") { return "MOVED" }
        return fact(why)
    }

    /// The first fact of a line, at most 18 characters.
    static func fact(_ line: String) -> String {
        let first = line.components(separatedBy: " · ").first ?? line
        return first.count <= 18 ? first : String(first.prefix(17)) + "…"
    }

    /// Where the text stands against the file: "CURRENT" for a deleted file and the copy shown
    /// offline, and "SAVING" for good once a save couldn't be made (the QA review's F12).
    static func onDisk(_ document: Document) -> String {
        if document.awaitingDownload { return "NOT HERE YET" }
        if document.deleted { return document.iCloudOff && document.dirty ? "IN THE RECOVERY FOLDER" : "GONE" }
        if case .problem(let why) = document.state, document.dirty {
            if why == Document.diskFull || why.hasPrefix("COULDN'T WRITE THE RECOVERY JOURNAL") { return "NOT SAVED · IN MEMORY" }
            if why.hasPrefix("COULDN'T SAVE") || why.hasPrefix("COULDN'T RESTORE") { return "NOT SAVED · IN THE JOURNAL" }
        }
        return document.dirty ? "SAVING" : "CURRENT"
    }

    /// A Sync Log line in the HUD's words: the event's glyph and word (the Sync Log window's,
    /// SyncLogDisplay), then its size or time for an opening, a save or an upload, and its
    /// detail for the rest: "= SAVED · 2.4 KB", "▲ UPLOADED · 514 MS", "✓ MERGED · CLEAN: 1
    /// CHANGE FROM STUDIO ONTO THIS MAC'S EDITS".
    static func line(_ event: SyncEvent) -> String {
        var parts = ["\(event.glyph) \(event.word.uppercased())"]
        let plain = ["open", "save", "upload"].contains(event.event) && !event.needsLook
        if plain {
            if event.event == "upload", let ms = event.ms {
                parts.append(ms < 1_000 ? "\(ms) MS" : String(format: "%.1f S", Double(ms) / 1_000))
            } else if let size = event.size {
                parts.append(bytes(size))
            }
        } else if let detail = event.detail, !detail.isEmpty {
            parts.append(hudDetail(detail))
        }
        return parts.joined(separator: " · ")
    }

    /// A Sync Log detail in the HUD's grammar: paths as their file's name, and its semicolons and
    /// colons as the HUD's dots (the QA review's F67: "…FOLDER (ICLOUD DRIVE IS OFF): /USERS/…; …").
    static func hudDetail(_ detail: String) -> String {
        // A path runs from its "/" to the next "; ", ", ", ": " or ")", or the end: the folders on
        // the way have spaces (Mobile Documents, Application Support), so a word isn't one.
        let text = detail as NSString
        var named = "", from = 0
        for match in pathPattern.matches(in: detail, range: NSRange(location: 0, length: text.length)) {
            named += text.substring(with: NSRange(location: from, length: match.range.location - from))
            named += (text.substring(with: match.range) as NSString).lastPathComponent
            from = NSMaxRange(match.range)
        }
        named += text.substring(from: from)
        return named.replacingOccurrences(of: "; ", with: " · ").replacingOccurrences(of: ": ", with: " · ").uppercased()
    }

    private static let pathPattern = try! NSRegularExpression(pattern: #"(?<![^\s(])/[^;,)]+?(?=[;,:]\s|\)|$)"#)

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file).uppercased()
    }
}
