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
            Text("NIB://SYNC").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
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
            }
            .font(HUDFont.terminal(18))
        }
        .accessibilityElement(children: .combine)
    }

    private var iCloudPanel: some View {
        HUDPanel(document.untitled || !document.inICloud ? "This Mac" : "iCloud") {
            HUDRow("STATE", Self.stateWord(document.state))
            HUDRow("SAVED", SyncState.clock.string(from: document.savedAt))
            HUDRow("UPLOADED", document.untitled ? "NEVER" : !document.inICloud ? "NOT IN ICLOUD" : document.uploadedAt.map { SyncState.clock.string(from: $0) } ?? "—")
            HUDRow("ON DISK", document.dirty ? "SAVING" : "CURRENT")
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
            let time = other.loaded.time
            let value = switch other.delivery {
            case .same: "✓ \(SyncState.clock.string(from: time))"
            case .newer: "▼ NEWER · \(Self.short.string(from: time))"
            case .earlier: "OLDER · \(Self.short.string(from: time))"
            }
            rows.append((other.device.uppercased(), value))
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

    private func warningPanel(_ warning: Warning) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            hudText("✕ WARNING", glyphSize: 9).font(HUDFont.label())
            Group {
                Text("\(warning.count) CONFLICT\(warning.count == 1 ? "" : "S")")
                Text(warning.lines.count == 1 ? "LINE \(warning.lines.lowerBound)" : "LINES \(warning.lines.lowerBound)-\(warning.lines.upperBound)")
                Text("BOTH SIDES KEPT IN THE FILE")
            }
            .font(HUDFont.terminal(18))
            Spacer(minLength: 0)
            Button { document.resolveConflicts() } label: {
                Text("RESOLVE ⌥⌘R").font(HUDFont.label()).underline()
            }
            .buttonStyle(.plain)
            .help("Open the merge view (⌥⌘R)")
            .disabled(document.merge != nil)
        }
        .foregroundStyle(HUDColor.onFailure)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(HUDColor.failure)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning: \(warning.count) conflict\(warning.count == 1 ? "" : "s"), \(warning.lines.count == 1 ? "line \(warning.lines.lowerBound)" : "lines \(warning.lines.lowerBound) to \(warning.lines.upperBound)"), both sides kept in the file")
    }

    // MARK: Words

    /// The state's glyph and words, without its time (the rows have the times).
    static func stateWord(_ state: SyncState) -> String {
        switch state {
        case .opening: "· OPENING"
        case .notDownloaded: "◐ DOWNLOADING"
        case .offline: "◐ OFFLINE"
        case .editing: "· EDITING"
        case .saved: "= SAVED LOCALLY"
        case .savedHere: "✓ SAVED"
        case .uploading: "▲ UPLOADING"
        case .local: "= THIS MAC ONLY"
        case .synced: "✓ SYNCED"
        case .waiting: "‖ WAITING"
        case .problem: "✕ PROBLEM"
        }
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
            parts.append(detail.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file).uppercased()
    }

    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
