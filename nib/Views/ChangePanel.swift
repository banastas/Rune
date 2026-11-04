// Changes since the last commit (PRD ED12): a click on a mark in the gutter shows that change, the
// committed lines it stands in place of, with REVERT and COPY, in the HUD's boxed style (as Sublime
// Text's diff popup and its Revert Hunk). A popover beside the gutter: Escape or a click elsewhere
// closes it. Revert is an edit like typing, one ⌘Z step (`GitMarks.revert`).

import AppKit
import NibText
import SwiftUI

@MainActor
enum ChangePanel {
    private static var popover: NSPopover?
    /// The change showing, while it's up.
    private(set) static var current: LineChanges.Hunk?

    static var isShown: Bool { popover?.isShown == true }

    static func show(_ hunk: LineChanges.Hunk, for document: Document, relativeTo rect: NSRect, of view: NSView) {
        close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)   // dark only (A17)
        let content = ChangePanelView(
            hunk: hunk,
            revert: { [weak document] in
                close()
                document?.git.revert(hunk)
            },
            copy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hunk.committed.map { $0 + "\n" }.joined(), forType: .string)
                close()
            })
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize   // as tall as its lines, not the HUD panel's room
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
        self.popover = popover
        current = hunk
        Announce.sentence(GitMarks.spoken(hunk, reverted: false))
    }

    static func close() {
        popover?.close()
        popover = nil
        current = nil
    }

    #if DEBUG
    /// The scenarios' REVERT and COPY, as a click on them.
    static func press(_ button: String, in document: Document) {
        guard let hunk = current else { return }
        if button == "REVERT" {
            close()
            document.git.revert(hunk)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hunk.committed.map { $0 + "\n" }.joined(), forType: .string)
            close()
        }
    }
    #endif
}

private struct ChangePanelView: View {
    let hunk: LineChanges.Hunk
    let revert: () -> Void
    let copy: () -> Void

    /// Committed lines shown; past that, how many more.
    static let shownLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hudText(title, glyphSize: 9).font(HUDFont.label()).foregroundStyle(HUDColor.dim).lineLimit(1)
            HUDPanel(hunk.committed.isEmpty ? "Not in the last commit" : "In the last commit") {
                if hunk.committed.isEmpty {
                    Text("REVERT TAKES \(plural(hunk.lines.count, "THIS LINE", "THESE \(hunk.lines.count) LINES")) OUT")
                        .font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hunk.committed.prefix(Self.shownLines).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(Font(Scheme.font as CTFont))
                    .foregroundStyle(Color(nsColor: Scheme.lineDiffDeleted))
                    if hunk.committed.count > Self.shownLines {
                        let more = hunk.committed.count - Self.shownLines
                        Text("+ \(more) MORE LINE\(more == 1 ? "" : "S")").font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                    }
                }
            }
            HStack(spacing: 16) {
                Button(action: revert) { Text("REVERT").underline() }
                    .help("Put the committed lines back (⌘Z takes it back)")
                if !hunk.committed.isEmpty {
                    Button(action: copy) { Text("COPY").underline() }
                        .help("Copy the committed lines")
                }
            }
            .buttonStyle(.plain)
            .font(HUDFont.label())
            .foregroundStyle(HUDColor.bright)
        }
        .padding(14)
        .frame(minWidth: 240, maxWidth: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(HUDColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(GitMarks.spoken(hunk, reverted: false))
    }

    /// "▼ CHANGED · LINES 4–6", "▼ ADDED · LINE 9", "▼ DELETED · BEFORE LINE 7".
    private var title: String {
        let first = hunk.lines.lowerBound + 1
        if hunk.lines.isEmpty { return "▼ \(hunk.committed.count) DELETED · BEFORE LINE \(first)" }
        let lines = hunk.lines.count == 1 ? "LINE \(first)" : "LINES \(first)–\(hunk.lines.upperBound)"
        return "▼ \(hunk.committed.isEmpty ? "ADDED" : "CHANGED") · \(lines)"
    }

    private func plural(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? one : many }
}
