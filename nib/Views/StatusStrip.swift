// The status strip (PRD §5.2, A2): one always-dark 24-pt line under the text in
// Blit's HUD language. Left: the sync state (glyph and words, V4; a muted-red tag
// only for a conflict or a problem, V3), which opens the sync HUD when clicked (§5.3).
// Right: line, column, syntax, encoding, line endings, in fixed-width slots (V10).
// Clicking the syntax picks another (HL1).

import NibText
import SwiftUI

struct StatusStrip: View {
    let document: Document
    @State private var lineAnswer = ""
    @FocusState private var lineFieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { document.toggleSyncDetails() } label: { syncState }
                .buttonStyle(.plain)
                .help(tooltip + (document.syncDetailsShown ? " Click to hide the details (⇧⌘Y)." : " Click for the details (⇧⌘Y)."))
                .accessibilityLabel("\(document.url.lastPathComponent), \(Self.spokenState(document))")
                .accessibilityHint(document.syncDetailsShown ? "Hides the sync details" : "Shows the sync details")
            if let offer = document.trashOffer {
                // The disk is full (§4.9, 13): deleted files hold their space until the Trash is emptied.
                Button { Task { await document.emptyTrashForSpace() } } label: {
                    Text(offer.label).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.bright).underline()
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Permanently erase the Trash, to give this Mac's disk its space back (asks first)")
                .accessibilityLabel(offer.spoken)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if document.goingToLine {
                    // Go to Line (⌃G, or a click on the slot): "12", or "12:5" for a column too.
                    Text("GO TO LN ")
                    TextField("", text: $lineAnswer)
                        .textFieldStyle(.plain)
                        .frame(width: 70)
                        .foregroundStyle(HUDColor.bright)
                        .focused($lineFieldFocused)
                        .onSubmit { document.goToLine(lineAnswer); lineAnswer = "" }
                        .onExitCommand { lineAnswer = ""; document.goingToLine = false; document.editor.textView.window?.makeFirstResponder(document.editor.textView) }
                        .accessibilityLabel("Go to line")
                    Text(" · ")
                } else {
                    Button { document.goingToLine = true } label: {
                        Text("LN \(document.cursor.line), COL \(document.cursor.column)\(document.caretCount > 1 ? " · \(document.caretCount) CARETS" : "") · ")
                    }
                    .buttonStyle(.plain)
                    .help("Go to a line (⌃G)")
                    .accessibilityLabel("Line \(document.cursor.line), column \(document.cursor.column)\(document.caretCount > 1 ? ", \(document.caretCount) carets" : ""). Go to a line")
                }
                if document.highlightingOff {
                    // ED9: over 5 MB, no highlighting (and no syntax to choose), the size said instead.
                    let size = ByteCountFormatter.string(fromByteCount: Int64(document.fileBytes), countStyle: .file)
                    Text("HIGHLIGHTING OFF · \(size.uppercased())")
                        .help("Files over 5 MB aren't highlighted, so they stay quick to edit and save")
                        .accessibilityLabel("Highlighting off, \(size)")
                } else {
                    Menu { SyntaxMenuItems(document: document) } label: {
                        Text(document.syntaxName).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("The syntax for this file. Click to choose another.")
                    .accessibilityLabel("Syntax, \(document.syntaxSpokenName)")
                }
                // Indentation and line endings are menus, as the syntax is (F50); the encoding is
                // kept as the file has it.
                Text(" · ")
                Menu { IndentationMenuItems(document: document) } label: {
                    Text(document.indentationLabel).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How this file indents. Click to change it or convert it.")
                .accessibilityLabel("Indentation, \(document.indentationLabel.lowercased())")
                Text(" · \(document.format.encoding.label) · ")
                    .help("The encoding, kept as the file has it")
                    .accessibilityLabel("Encoding, \(document.format.encoding.label)")
                Menu { LineEndingMenuItems(document: document) } label: {
                    Text(document.format.lineEnding.label).font(HUDFont.terminal(16)).foregroundStyle(HUDColor.dim)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("This file's line endings. Click to change them.")
                .accessibilityLabel("Line endings, \(document.format.lineEnding.label)")
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
        .onChange(of: document.goingToLine) { _, open in if open { lineFieldFocused = true } }
        .onChange(of: lineFieldFocused) { _, focused in if !focused, document.goingToLine { document.goingToLine = false } }
        // One summary, as Blit's strip reads (AX1); its buttons still reachable inside.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.summary(document))
    }

    /// The sync state: a muted-red tag for a problem, then the glyph and words (or a notice). The
    /// tag stays while a notice shows: a notice hid a standing problem for up to 20 s (F40).
    private var syncState: some View {
        HStack(spacing: 10) {
            if let tag = document.state.tag {
                hudText(tag, glyphSize: 9)
                    .font(HUDFont.label(9))
                    .foregroundStyle(HUDColor.onFailure)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(HUDColor.failure)
                    .fixedSize()
            }
            hudText(document.notice ?? document.statusLine, glyphSize: 11)
                .font(HUDFont.terminal(16))
                .foregroundStyle(stateColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
    }

    /// "scratch.md, synced at 10:42:21, line 14, column 3, Markdown" (AX1).
    static func summary(_ document: Document) -> String {
        "\(document.url.lastPathComponent), \(spokenState(document)), line \(document.cursor.line), column \(document.cursor.column)\(document.caretCount > 1 ? ", \(document.caretCount) carets" : ""), \(document.highlightingOff ? "highlighting off" : document.syntaxSpokenName)"
    }

    /// "2 spaces, UTF-8, LF line endings".
    static func spokenDetails(_ document: Document) -> String {
        "\(document.indentationLabel.lowercased()), \(document.format.encoding.label), \(document.format.lineEnding.label) line endings"
    }

    /// The notice showing, or else the state, mid-sentence.
    static func spokenState(_ document: Document) -> String {
        let said = document.notice.map(Spoken.sentence) ?? document.statusSpoken
        guard let first = said.first else { return said }
        return first.lowercased() + said.dropFirst()
    }

    private var stateColor: Color { Self.color(notice: document.notice, state: document.state) }

    /// A failure's notice in the red's text tint, a wait's dim, the rest bright (V3; the QA
    /// review's F40: every notice was bright, its ✕ white).
    static func color(notice: String?, state: SyncState) -> Color {
        if let notice {
            if notice.hasPrefix("✕") { return HUDColor.failureText }
            if notice.hasPrefix("‖") { return HUDColor.dim }
            return HUDColor.bright
        }
        switch state {
        case .problem: return HUDColor.failureText
        default: return state.isDim ? HUDColor.dim : HUDColor.bright
        }
    }

    /// What the other Macs' receipts say (SY14), each Mac's time by its own clock.
    private var receipts: String {
        guard !document.otherMacs.isEmpty else { return "" }
        // The HUD's and the panel's words, as sentences (F41).
        return document.otherMacs.map(\.sentence).joined(separator: "; ") + ". Receipts come through iCloud too, so they're as late as iCloud is. "
    }

    /// The precise meaning, in sentence case (PRD §4.5, "tooltips carry the precise meaning").
    private var tooltip: String {
        let hold = document.held
            ? "Rune holds this file: iCloud's own syncing is paused, and Rune uploads each version itself, refusing to overwrite a newer one."
            : "iCloud syncs this file on its own schedule."
        switch document.state {
        case .synced: return "iCloud has this exact version. Other Macs get it when they check, which Rune does whenever it comes forward. " + receipts + hold
        case .saved: return "Saved on this Mac. iCloud doesn't have this version yet. " + hold
        case .savedHere: return "Saved to this Mac's disk. This file isn't in iCloud Drive, so there's nothing to sync: it's on this Mac only."
        case .local: return "An untitled buffer: Rune keeps it on this Mac, in its own folder, and never syncs it. Closing it keeps the text in History for 30 days, and File › Reopen Closed File brings it back; File › Save… makes it a file."
        case .uploading: return "Uploading this version to iCloud. " + hold
        default: return document.state.spoken + ". " + hold
        }
    }
}

/// Right-click on the strip (PRD §5.2): Save Now, Show Sync Log (on this file), Show
/// History, Show in Finder.
struct StripMenu: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // File › Save's own: ⌘S's tidying, and Save… for an untitled buffer (it skipped both: F45).
        Button(document.untitled ? "Save…" : "Save Now") { AppDelegate.save(document) }
        if !document.untitled {   // untitled buffers stay out of the Sync Log (ED3)
            Button("Show Sync Log") { SyncLogModel.shared.show(file: document.url, openWindow: openWindow) }
        }
        Button("Show History") { openWindow(id: "history", value: document.url) }
        // "Show in Finder", as everywhere else; not for an untitled buffer, whose file is Nib's own (F45).
        if !document.untitled, !document.deleted {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
        }
    }
}

/// The syntax menu (HL1), on the strip's syntax and in View › Syntax: Automatic follows the
/// file's name and first line; a pick is kept for the file.
/// View › Indentation and the strip's indentation slot (the QA review's F50): tabs or spaces
/// and how wide, kept for the file; Guess Indentation from the File; and Convert Indentation,
/// as Sublime's View › Indentation has them.
struct IndentationMenuItems: View {
    let document: Document?

    var body: some View {
        let now = document?.indentation
        let tabs = if case .tabs = now { true } else { false }
        Toggle("Indent Using Tabs", isOn: Binding(get: { document != nil && tabs },
                                                  set: { if $0, let width = now?.width { document?.setIndentation(.tabs(width: width)) } }))
        Toggle("Indent Using Spaces", isOn: Binding(get: { document != nil && !tabs },
                                                    set: { if $0, let width = now?.width { document?.setIndentation(.spaces(width)) } }))
        Divider()
        ForEach([2, 3, 4, 8], id: \.self) { width in
            Toggle("Indent Width: \(width)", isOn: Binding(get: { now?.width == width },
                                                          set: { if $0 { document?.setIndentation(tabs ? .tabs(width: width) : .spaces(width)) } }))
        }
        Divider()
        Button("Guess Indentation from the File") { document?.guessIndentation() }
        Divider()
        Button("Convert Indentation to Spaces") { document?.convertIndentation(toTabs: false) }
        Button("Convert Indentation to Tabs") { document?.convertIndentation(toTabs: true) }
    }
}

/// View › Line Endings and the strip's line-endings slot (F50): the file's, from its next save.
struct LineEndingMenuItems: View {
    let document: Document?

    var body: some View {
        ForEach(LineEnding.allCases, id: \.self) { ending in
            Toggle(Self.title(ending), isOn: Binding(get: { document?.format.lineEnding == ending },
                                                     set: { if $0 { document?.setLineEnding(ending) } }))
        }
    }

    static func title(_ ending: LineEnding) -> String {
        switch ending {
        case .lf: "LF (Mac, Unix)"
        case .crlf: "CRLF (Windows)"
        case .cr: "CR (Classic Mac OS)"
        }
    }
}

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
