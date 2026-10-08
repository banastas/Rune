// Window › Sync Log (⌥⌘L, PRD SY13, A13): every save, upload, arrival, merge and conflict
// this Mac's Nib recorded, newest first, searchable by file, event, device, detail or
// SHA-256, filterable, with the whole record, Show in Finder, Show History and Copy SHA-256
// for the selected line. It follows the log as lines are added. Blit's Transfer Log, for
// syncing. The log itself is `~/Library/Application Support/nib/sync.jsonl`.

import AppKit
import NibSync
import SwiftUI

struct SyncLogRow: Identifiable, Hashable {
    let id: Int
    let event: SyncEvent

    var time: Date { event.time }
    var word: String { event.word }
    var name: String { event.fileName }
    var size: Int { event.size ?? -1 }
    var took: Int { event.ms ?? -1 }
    var detail: String { event.detail ?? "" }

    static func == (a: SyncLogRow, b: SyncLogRow) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The window's lines, search and filter; shared, so the strip's Show Sync Log can open it
/// on one file.
@MainActor
@Observable
final class SyncLogModel {
    static let shared = SyncLogModel()

    private(set) var rows: [SyncLogRow] = []
    var search = ""
    var filter = SyncEvent.Category.all
    var sortOrder = [KeyPathComparator(\SyncLogRow.time, order: .reverse)]
    private(set) var loaded = false

    static var url: URL { NibPaths.support.appendingPathComponent("sync.jsonl") }
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Where the lines read so far end in the log, and the windows open on it. Only while one is
    /// open does a new line mean a read, and then of what's new: once used, every line read the
    /// whole log again, window open or not, for the rest of the session (the QA review's F33).
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var windows = 0
    /// Reads of the whole log, for the `synclog` scenario.
    @ObservationIgnored private(set) var wholeReads = 0

    private init() {
        NotificationCenter.default.addObserver(forName: SyncLog.didAppend, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncLogModel.shared.scheduleReload() }
        }
    }

    var shown: [SyncLogRow] {
        rows.filter { $0.event.belongs(to: filter) && $0.event.matches(search) }.sorted(using: sortOrder)
    }

    /// Lines come in bursts (a save, an upload, a fetch): read what's new once they settle.
    func scheduleReload() {
        guard windows > 0 else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.readNew()
        }
    }

    /// A window opened: the whole log.
    func opened() async {
        windows += 1
        await reload()
    }

    /// A window closed: with none left, the lines are let go, and nothing's read till one opens.
    func closed() {
        windows = max(0, windows - 1)
        guard windows == 0 else { return }
        pending?.cancel()
        rows = []
        offset = 0
        loaded = false
    }

    func reload() async {
        let url = Self.url
        let (events, end) = await Task.detached(priority: .userInitiated) { SyncLog(url: url).read(from: 0) }.value
        rows = events.enumerated().map { SyncLogRow(id: $0.offset, event: $0.element) }
        offset = end
        wholeReads += 1
        loaded = true
    }

    /// The lines added since the last read; the whole log again if it was replaced.
    private func readNew() async {
        let url = Self.url, from = offset
        let (events, end) = await Task.detached(priority: .userInitiated) { SyncLog(url: url).read(from: from) }.value
        guard windows > 0 else { return }
        guard end >= from, offset == from else { await reload(); return }
        let first = rows.count
        rows += events.enumerated().map { SyncLogRow(id: first + $0.offset, event: $0.element) }
        offset = end
    }

    /// The strip's Show Sync Log: the window, on that file.
    func show(file url: URL, openWindow: OpenWindowAction) {
        search = url.lastPathComponent
        filter = .all
        openWindow(id: "sync-log")
    }
}

struct SyncLogView: View {
    @State private var selection: SyncLogRow.ID?
    /// Whether the selected line's file is there, looked at when the selection changes, not at
    /// every draw (the QA review's F35).
    @State private var selectedExists = false
    @Environment(\.openWindow) private var openWindow
    /// The search field, for Edit › Find… (⌘F) with this window in front: it went to the text
    /// commands, and nothing here took it (the QA review's §5).
    @FocusState private var searching: Bool
    static let find = Notification.Name("NibSyncLogFind")

    var body: some View {
        @Bindable var model = SyncLogModel.shared
        let shown = model.shown
        VStack(spacing: 0) {
            Table(shown, selection: $selection, sortOrder: $model.sortOrder) {
                TableColumn("") { row in
                    hudText(row.event.glyph, glyphSize: 10)
                        .foregroundStyle(row.event.failed || row.event.event == "conflict" ? HUDColor.failureText : row.event.glyph == "·" ? .secondary : .primary)
                        .help(row.event.word)
                        .accessibilityHidden(true)   // the Event column says it in words (F39)
                }
                .width(16)
                TableColumn("Time", value: \.time) { row in
                    // As History names times, "Today 22:29:37" (it was "Oct 6  22:29:37": F79).
                    Text(HistoryView.when(row.time)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)
                TableColumn("Event", value: \.word) { row in
                    Text(row.word).foregroundStyle(row.event.failed ? HUDColor.failureText : .primary)
                }
                .width(min: 90, ideal: 116)
                TableColumn("File", value: \.name) { row in Text(row.name).lineLimit(1) }
                    .width(min: 90, ideal: 140)
                TableColumn("Detail", value: \.detail) { row in
                    Text(row.detail).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                }
                .width(min: 160, ideal: 250)
                TableColumn("Size", value: \.size) { row in
                    Text(row.event.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")   // "3 KB", as elsewhere (F79)
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 76)
                TableColumn("Took", value: \.took) { row in
                    Text(row.event.ms.map { "\($0) ms" } ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 72)
                TableColumn("SHA-256") { row in
                    Text(row.event.sha256.map { String($0.prefix(8)) } ?? "—")
                        .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if model.loaded, shown.isEmpty {
                    Text(model.rows.isEmpty ? "Nothing logged yet" : "No matches").foregroundStyle(.secondary)   // W6
                }
            }
            if let row = model.rows.first(where: { $0.id == selection }) {
                Divider()
                detail(row)
            }
        }
        .searchable(text: $model.search, prompt: "File, event, device, detail or SHA-256")
        .searchFocused($searching)
        .onReceive(NotificationCenter.default.publisher(for: Self.find)) { _ in searching = true }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.filter) {
                    ForEach(SyncEvent.Category.allCases) { Text($0.rawValue).tag($0).help($0.help) }
                }
                .pickerStyle(.segmented)
                .help(model.filter.help)
            }
            ToolbarItem {
                Button("Show Log File", systemImage: "doc.text.magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([SyncLogModel.url])
                }
                .help("Show sync.jsonl, the log itself, in Finder")
            }
        }
        .navigationTitle("Sync Log")
        .navigationSubtitle(!model.loaded ? "Loading…" : shown.count == model.rows.count ? "\(model.rows.count.formatted()) events" : "\(shown.count.formatted()) of \(model.rows.count.formatted()) events")   // not "0 events" while it reads (F79)
        // A selection the search or filter hides goes with it (F79: kept, its detail still showing).
        .onChange(of: model.search) { _, _ in if let selection, !model.shown.contains(where: { $0.id == selection }) { self.selection = nil } }
        .onChange(of: model.filter) { _, _ in if let selection, !model.shown.contains(where: { $0.id == selection }) { self.selection = nil } }
        .frame(minWidth: 820, minHeight: 360)
        .onChange(of: selection) { _, id in
            let path = SyncLogModel.shared.rows.first { $0.id == id }?.event.path
            selectedExists = path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
        .task { await SyncLogModel.shared.opened() }
        .onDisappear { SyncLogModel.shared.closed() }
    }

    @ViewBuilder private func detail(_ row: SyncLogRow) -> some View {
        let event = row.event
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("File").foregroundStyle(.secondary)
                Text((event.path as NSString).abbreviatingWithTildeInPath).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            GridRow {
                Text("When").foregroundStyle(.secondary)
                Text("\(HistoryView.when(event.time)) · \(event.device) · \(event.word) (“\(event.event)”)").textSelection(.enabled)
            }
            if let sha = event.sha256 {
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(sha).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            if event.size != nil || event.ms != nil {
                GridRow {
                    Text("Size, time").foregroundStyle(.secondary)
                    Text([event.size.map { "\($0.formatted()) bytes" }, event.ms.map { "\($0) ms" }].compactMap { $0 }.joined(separator: " · "))
                }
            }
            if let detail = event.detail {
                GridRow {
                    Text("Detail").foregroundStyle(.secondary)
                    Text(detail).textSelection(.enabled).foregroundStyle(event.failed ? HUDColor.failureText : .primary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        HStack {
            let url = URL(fileURLWithPath: event.path)
            if selectedExists {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                // A file that isn't open: its History window offers to open it (F35).
                Button("Show History") { openWindow(id: "history", value: url) }
            }
            if let sha = event.sha256 {
                Button("Copy SHA-256") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                }
            }
            Spacer()
        }
        .padding([.horizontal, .bottom], 12)
    }
}
