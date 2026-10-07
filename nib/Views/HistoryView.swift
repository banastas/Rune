// The History window (PRD SY13): every version History keeps of the file, newest first,
// with where each came from, and a preview in the editor's font. Restore This Version puts
// it back in the buffer as one edit (⌘Z undoes it); the version it replaces stays here.
// Native list and buttons (V1); History stays on this Mac.

import AppKit
import NibSync
import NibText
import SwiftUI

struct HistoryView: View {
    let document: Document
    @State private var selection: String?
    /// The selected version's text, read and checked off the main thread (F57: read and hashed in
    /// `body`, 2.4 MB a selection, under History's lock).
    @State private var preview = ""

    private struct Row: Identifiable {
        let entry: HistoryEntry
        var id: String { entry.sha256 + "@" + String(entry.time.timeIntervalSince1970) }
    }

    private var rows: [Row] { document.historyEntries.reversed().map(Row.init) }

    var body: some View {
        let rows = self.rows
        let selected = rows.first { $0.id == selection } ?? rows.first
        HSplitView {
            List(rows, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(row.entry.time)).monospacedDigit()
                    Text("\(row.entry.source) · \(ByteCountFormatter.string(fromByteCount: Int64(row.entry.size), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(row.id)
            }
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)   // a sidebar: it took half the window (F58)
            VStack(alignment: .leading, spacing: 8) {
                VersionText(text: preview)
                    .task(id: selected?.entry.sha256) {
                        let history = document.history, sha = selected?.entry.sha256
                        preview = await Task.detached(priority: .userInitiated) {
                            sha.flatMap { history.data($0) }.map { TextFile.decode($0).text } ?? ""
                        }.value
                    }
                HStack {
                    Text(selected.map { "\(Self.when($0.entry.time)) · \($0.entry.source)" } ?? "No versions yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore This Version") { if let selected { document.restore(selected.entry) } }
                        .disabled(selected == nil)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle("History · \(document.url.lastPathComponent)")
        .onAppear { if selection == nil { selection = rows.first?.id } }
    }

    /// "Today 15:48:31", "Yesterday 09:12:05", "Sep 26 17:40:00".
    static func when(_ date: Date) -> String {
        let time = SyncState.clock.string(from: date)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }
}

/// A version's text, read-only, in the editor's font and colors.
struct VersionText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.backgroundColor = Scheme.background
        let view = NSTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isRichText = false
        view.font = Scheme.font
        view.textColor = Scheme.foreground
        view.backgroundColor = Scheme.background
        view.textContainerInset = NSSize(width: 8, height: 6)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.scroll(.zero)
    }
}

/// File › Revert To: the last fifteen versions, and the History window for the rest (ED4).
struct RevertToMenu: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recent = Array(document.historyEntries.reversed().prefix(15))   // read off the main thread (F57)
        return Menu("Revert To") {
            ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                Button("\(HistoryView.when(entry.time)) · \(entry.source)") { document.restore(entry) }
            }
            if !recent.isEmpty { Divider() }
            Button("Browse All Versions…") { openWindow(id: "history", value: document.url) }
        }
    }
}

/// A History window, for the file it was opened for, while that file is open.
struct HistoryWindow: View {
    let url: URL?
    /// The document as the window opened: kept, so its closing is seen (F2).
    @State private var document: Document?
    @Environment(\.dismiss) private var dismiss

    init(url: URL?) {
        self.url = url
        _document = State(initialValue: url.flatMap(Documents.existing(for:)) ?? (url == nil ? Documents.scratch : nil))
    }

    /// What the window shows: the file's History while it's open; for one that isn't, a way to
    /// open it (it said "Open the file to see its History." with no way to, from the Sync Log:
    /// the QA review's F35); for one that's gone, that it is.
    enum Shown: Equatable { case history, notOpen(String), gone(String), nothing }

    static func shown(url: URL?, document: Document?) -> Shown {
        if let document, !document.closed { return .history }
        guard let url else { return .nothing }
        return FileManager.default.fileExists(atPath: url.path) ? .notOpen(url.lastPathComponent) : .gone(url.lastPathComponent)
    }

    var body: some View {
        Group {
            switch Self.shown(url: url, document: document) {
            case .history:
                if let document {
                    HistoryView(document: document)
                        .background(WindowConfigurator { $0.tabbingMode = .disallowed })
                }
            case .notOpen(let name):
                VStack(spacing: 12) {
                    Text("“\(name)” isn't open. Its History shows here once it is.")
                        .foregroundStyle(.secondary)
                    Button("Open “\(name)”") { if let url { open(url) } }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(20)
                .frame(minWidth: 400, minHeight: 200)
            case .gone(let name):
                message("“\(name)” isn't there any more.")
            case .nothing:
                message("Open the file to see its History.")
            }
        }
        // Its file closed: the window goes too, as the document it shows is let go (the QA
        // review's F2: Restore here saved into the closed file).
        .onChange(of: document?.closed ?? false) { _, closed in if closed { dismiss() } }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(20)
            .frame(minWidth: 400, minHeight: 200)
    }

    /// Opens the file, and shows its History once it's open.
    private func open(_ url: URL) {
        guard AppDelegate.openFile(url) else { return }
        Task {
            for _ in 0..<100 {
                if let opened = Documents.existing(for: url), opened.ready { document = opened; return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
