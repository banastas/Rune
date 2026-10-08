// The History window (PRD SY13): every version History keeps of the file, newest first,
// with where each came from, and a preview in the editor's font. Restore This Version puts
// it back in the buffer as one edit (⌘Z undoes it); the version it replaces stays here.
// Native list and buttons (V1); History stays on this Mac.

import AppKit
import NibSync
import NibText
import SwiftUI

/// What Find in History (SY18) opens the History window on: the version that has the search,
/// and the search, shown in whichever version is selected while the window's open.
struct HistoryFocus: Equatable {
    let sha256: String
    let time: Date
    let query: String
    let options: SearchOptions
}

struct HistoryView: View {
    let document: Document
    @State private var selection: String?
    /// The selected version's text, read and checked off the main thread (F57: read and hashed in
    /// `body`, 2.4 MB a selection, under History's lock).
    @State private var preview = ""
    /// Find in History's search in the selected version (SY18), and the one shown.
    @State private var matches: [NSRange] = []
    @State private var current = 0
    @State private var copied: String?

    private struct Row: Identifiable {
        let entry: HistoryEntry
        var id: String { HistoryView.rowID(entry.sha256, entry.time) }
    }

    nonisolated static func rowID(_ sha256: String, _ time: Date) -> String { sha256 + "@" + String(time.timeIntervalSince1970) }

    private var rows: [Row] { document.historyEntries.reversed().map(Row.init) }

    var body: some View {
        let rows = self.rows
        let selected = rows.first { $0.id == selection } ?? rows.first
        let focus = document.historyFocus
        HSplitView {
            List(rows, selection: $selection) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.when(row.entry.time)).monospacedDigit()
                    Text("\(Self.source(row.entry.source)) · \(ByteCountFormatter.string(fromByteCount: Int64(row.entry.size), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(row.id)
            }
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)   // a sidebar: it took half the window (F58)
            VStack(alignment: .leading, spacing: 8) {
                VersionText(text: preview, highlights: matches, current: matches.isEmpty ? nil : current)
                    .task(id: TaskKey(sha: selected?.entry.sha256, focus: focus)) {
                        let history = document.history, sha = selected?.entry.sha256
                        let found: (String, [NSRange]) = await Task.detached(priority: .userInitiated) {
                            let text = sha.flatMap { history.data($0) }.map { TextFile.decode($0).text } ?? ""
                            let hits = focus.flatMap { try? TextSearch.matches(of: $0.query, in: text, options: $0.options) } ?? []
                            return (text, hits)
                        }.value
                        preview = found.0
                        matches = found.1
                        current = 0
                    }
                if let focus {
                    // Find in History (SY18): the search, in this version, and how to get it back.
                    HStack {
                        Text(searchLine(focus))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("History is this Mac's, for this file: text another Mac deleted before this Mac had it isn't here.")
                        Spacer()
                        Button("Next Match") { current = (current + 1) % max(matches.count, 1) }
                            .disabled(matches.count < 2)
                            .help("Show the next match in this version")
                        Button("Copy Paragraph") { copyParagraph() }
                            .disabled(matches.isEmpty)
                            .help("Copy the paragraph round this match (or its code block), to paste back into the text")
                    }
                    .padding(.horizontal, 8)
                }
                HStack {
                    Text(copied ?? selected.map { "\(Self.when($0.entry.time)) · \(Self.source($0.entry.source))" } ?? "No versions yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Off for the version the text is now: it did nothing (the QA review's F80).
                    Button("Restore This Version") { if let selected { document.restore(selected.entry) } }
                        .disabled(selected == nil || (selected?.entry.sha256 == document.versionSHA && !document.dirty))
                        .help(selected?.entry.sha256 == document.versionSHA && !document.dirty ? "This is the text as it is now" : "Put this version back in the text, as one edit ⌘Z undoes")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(minWidth: 360)
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle("History · \(document.url.lastPathComponent)")
        .navigationSubtitle(document.untitled ? "On this Mac only" : ScratchLocation.place(of: document.url))   // where it is (F80)
        .onAppear {
            if let focus = document.historyFocus { selection = Self.rowID(focus.sha256, focus.time) }
            if selection == nil { selection = rows.first?.id }
        }
        .onChange(of: document.historyFocus) { _, focus in
            if let focus { selection = Self.rowID(focus.sha256, focus.time) }
        }
        .onDisappear { document.historyFocus = nil }   // History opened another way shows no search
    }

    private struct TaskKey: Equatable { let sha: String?; let focus: HistoryFocus? }

    /// "“lost line” · 2 of 3 in this version", or that it isn't in this one. That History is this
    /// Mac's and this file's is said in its help (SY18), and in the find bar's.
    private func searchLine(_ focus: HistoryFocus) -> String {
        let what = "“\(focus.query)”"
        if matches.isEmpty { return "\(what) isn't in this version" }
        return "\(what) · \(matches.count == 1 ? "1 match" : "\(current + 1) of \(matches.count)") in this version"
    }

    /// Copy Paragraph (SY18): the paragraph round the match shown (its code block, inside one),
    /// as Copy Block (⇧⌘C) takes one from the text.
    private func copyParagraph() {
        guard matches.indices.contains(current), let said = Self.copyParagraph(in: preview, at: matches[current]) else { NSSound.beep(); return }
        copied = said
        Announce.sentence(said)
        Task { try? await Task.sleep(for: .seconds(4)); if copied == said { copied = nil } }
    }

    /// The paragraph (or code block) round `match` onto the clipboard as plain text; what to say,
    /// or nil if there's none there. The button's work, which the `findhistory` scenario runs on
    /// the window's text (SwiftUI's buttons can't be pressed from a scenario).
    static func copyParagraph(in text: String, at match: NSRange) -> String? {
        guard let block = TextBlocks.block(at: match.location, in: text) else { return nil }
        let copied = (text as NSString).substring(with: block.range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        let lines = copied.components(separatedBy: "\n").count
        return "Copied the \(block.kind == .code ? "code block" : "paragraph"), \(lines) line\(lines == 1 ? "" : "s"). ⌘V puts it in the text."
    }

    /// A version's source with a capital, "Saved", "Merged from Air", "iCloud conflict version
    /// from Air" (lowercase, "saved · 588 bytes", it read as a fragment: F80).
    static func source(_ source: String) -> String {
        source.hasPrefix("iCloud") ? source : source.prefix(1).uppercased() + source.dropFirst()
    }

    /// "Today 15:48:31", "Yesterday 09:12:05", "Sep 26 17:40:00".
    static func when(_ date: Date) -> String {
        let time = SyncState.clock.string(from: date)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " " + time
    }
}

/// A version's text, read-only, in the editor's font and colors; Find in History's matches
/// (SY18) in the find highlight, the current one selected and in view.
struct VersionText: NSViewRepresentable {
    let text: String
    var highlights: [NSRange] = []
    var current: Int?

    final class Coordinator { var shown: (text: Int, highlights: [NSRange], current: Int?)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

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
        guard let view = scroll.documentView as? NSTextView else { return }
        let key = (text: text.hashValue, highlights: highlights, current: current)
        if let shown = context.coordinator.shown, shown.text == key.text, shown.highlights == key.highlights, shown.current == key.current { return }
        let textChanged = context.coordinator.shown?.text != key.text
        context.coordinator.shown = key
        if textChanged {
            view.string = text
            view.scroll(.zero)
        }
        // Drawn as the editor draws Find's matches: TextKit 2 rendering attributes in the scheme's
        // find colors, not the selection (AppKit's inactive grey covered them).
        guard let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: content.documentRange)
        layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
        let length = (view.string as NSString).length, foreground = Scheme.findHighlightForeground
        func textRange(_ range: NSRange) -> NSTextRange? {
            guard NSMaxRange(range) <= length, let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }
        for range in highlights {
            guard let text = textRange(range) else { continue }
            layout.addRenderingAttribute(.backgroundColor, value: Scheme.findHighlight, for: text)
            if let foreground { layout.addRenderingAttribute(.foregroundColor, value: foreground, for: text) }
        }
        if let current, highlights.indices.contains(current), NSMaxRange(highlights[current]) <= length {
            view.reveal(highlights[current].location, linesAbove: 3)   // by geometry, never scrollRangeToVisible (Reveal.swift)
        }
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
                Button("\(HistoryView.when(entry.time)) · \(HistoryView.source(entry.source))") { document.restore(entry) }
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
