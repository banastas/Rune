// The status strip (PRD §5.2, A2): one always-dark 24-pt line under the text in
// Blit's HUD language. Left: the sync state (glyph and words, V4; a muted-red tag
// only for a conflict or a problem, V3). Right: line, column, syntax, encoding,
// line endings, in fixed-width slots (V10). Clicking the syntax picks another (HL1).

import NibText
import SwiftUI

struct StatusStrip: View {
    let document: Document

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                if document.notice == nil, let tag = document.state.tag {
                    hudText(tag, glyphSize: 9)
                        .font(HUDFont.label(9))
                        .foregroundStyle(HUDColor.onFailure)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(HUDColor.failure)
                        .fixedSize()
                }
                hudText(document.notice ?? document.state.line, glyphSize: 11)
                    .font(HUDFont.terminal(16))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(document.url.lastPathComponent), \(document.state.spoken)")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                Text("LN \(document.cursor.line), COL \(document.cursor.column) · ")
                    .accessibilityLabel("Line \(document.cursor.line), column \(document.cursor.column)")
                Menu { SyntaxMenuItems(document: document) } label: {
                    Text(document.syntaxName).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The syntax for this file. Click to choose another.")
                .accessibilityLabel("Syntax, \(document.syntaxName.capitalized)")
                Text(" · \(document.format.encoding.label) · \(document.format.lineEnding.label)")
            }
            .font(HUDFont.terminal(16))
            .monospacedDigit()
            .foregroundStyle(HUDColor.dim)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(HUDColor.background)
        .overlay(alignment: .top) { Rectangle().fill(HUDColor.border).frame(height: 0.5) }
        .environment(\.colorScheme, .dark)
        .help(tooltip)
        .contextMenu { StripMenu(document: document) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private var stateColor: Color {
        if document.notice != nil { return HUDColor.bright }
        switch document.state {
        case .problem: return HUDColor.failureText
        default: return document.state.isDim ? HUDColor.dim : HUDColor.bright
        }
    }

    /// The precise meaning, in sentence case (PRD §4.5, "tooltips carry the precise meaning").
    private var tooltip: String {
        let hold = document.held
            ? "Nib holds this file: iCloud's own syncing is paused, and Nib uploads each version itself, refusing to overwrite a newer one."
            : "iCloud syncs this file on its own schedule."
        switch document.state {
        case .synced: return "iCloud has this exact version. Other Macs get it when they check, which Nib does whenever it comes forward. " + hold
        case .saved: return "Saved on this Mac. iCloud doesn't have this version yet. " + hold
        case .uploading: return "Uploading this version to iCloud. " + hold
        default: return document.state.spoken + ". " + hold
        }
    }
}

/// Right-click on the strip (PRD §5.2): Save Now, Show History, Reveal in Finder.
struct StripMenu: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Save Now") { Task { await document.flush(reason: "strip") } }
        Button("Show History") { openWindow(id: "history", value: document.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
    }
}

/// The syntax menu (HL1), on the strip's syntax and in View › Syntax: Automatic follows the
/// file's name and first line; a pick is kept for the file.
struct SyntaxMenuItems: View {
    let document: Document?

    var body: some View {
        Toggle("Automatic (\(document?.detectedSyntax?.name ?? "Plain Text"))", isOn: picked(nil))
        Divider()
        ForEach(SyntaxPick.all, id: \.self) { pick in
            Toggle(pick.name, isOn: picked(pick))
        }
    }

    private func picked(_ pick: SyntaxPick?) -> Binding<Bool> {
        Binding(get: { document != nil && document?.pickedSyntax == pick },
                set: { if $0 { document?.pickSyntax(pick) } })
    }
}
