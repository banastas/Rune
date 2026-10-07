// The merge view (PRD §5.5): a sheet on the scratch window for many conflict blocks at
// once (Resolve… with more than three). Each version's whole text side by side, marked
// against the other (~ changed, + only here), in the editor's font and An Old Hope's diff
// tints; below, the result, editable, with the same frames and keys as the editor (⌘1, ⌘2,
// ⌘3, ⌥⌘↓/↑). Done (⌘↩) puts it in the buffer as one edit; Cancel (Escape) keeps the markers.
// Duplicates, iCloud conflict versions and History, its other uses, come later.

import AppKit
import NibSyntax
import NibText
import SwiftUI

@MainActor
@Observable
final class MergeSession {
    /// The buffer when the sheet opened: the base if it changes meanwhile.
    let original: String
    let first: ConflictText.Side
    let second: ConflictText.Side
    let marks: (first: [ConflictText.LineMark], second: [ConflictText.LineMark])
    let total: Int
    @ObservationIgnored let editor = Editor(minimap: false)
    private(set) var blocks: [ConflictBlock] = []
    private(set) var caretBlock: Int?
    /// Set by the sheet: Escape in the result cancels.
    @ObservationIgnored var cancel: (() -> Void)?

    var result: String { editor.textView.string }

    init(text: String, device: String, syntax: (language: SyntaxLanguage, root: String)?) {
        original = text
        let found = ConflictText.blocks(in: text)
        let sides = ConflictText.sides(of: text)
        // From every block's labels, not the first one's alone (the QA review's F34).
        first = .init(text: sides.first, label: Self.title(found.map(\.firstLabel), fallback: "First", device: device))
        second = .init(text: sides.second, label: Self.title(found.map(\.secondLabel), fallback: "Second", device: device))
        let marks = ConflictText.lineMarks(sides.first, sides.second)
        self.marks = (marks.a, marks.b)
        total = found.count
        editor.textView.string = text
        editor.syntax = syntax
        editor.textView.setAccessibilityLabel("Merge result")
        editor.onChange = { [weak self] in self?.update() }
        editor.onSelection = { [weak self] in self?.updateCaret() }
        editor.textView.onEscape = { [weak self] in self?.cancel?(); return true }
        editor.textView.onResolve = { [weak self] in self?.resolve($0) }   // VoiceOver's actions in a block (F60)
        editor.textView.setSelectedRange(NSRange(location: found.first?.first.location ?? 0, length: 0))
        update()
    }

    /// "Air · 10:42" → "AIR · 10:42", or "AIR · THIS MAC · 10:42" for this Mac's side.
    /// A pane's title from its side's label in every block: the name they share (or the names,
    /// two at most, else "SEVERAL"), and the time they share, or the span of their times. One
    /// source and one time for every block came from the first block alone (F34).
    static func title(_ labels: [String], fallback: String, device: String) -> String {
        guard !labels.isEmpty else { return fallback.uppercased() }
        var names: [String] = [], times: [String] = []
        for label in labels {
            let parts = label.components(separatedBy: " · ")
            if let name = parts.first, !names.contains(name) { names.append(name) }
            if parts.count > 1, !times.contains(parts[1]) { times.append(parts[1]) }
        }
        var title = names.count == 1 ? [names[0]] + (names[0] == device ? ["This Mac"] : [])
            : names.count == 2 ? [names.joined(separator: " / ")] : ["Several"]
        let clock = times.allSatisfy { $0.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil }
        if times.count == 1 { title.append(times[0]) } else if clock, let earliest = times.min(), let latest = times.max() { title.append("\(earliest)-\(latest)") }
        return title.joined(separator: " · ").uppercased()
    }

    func update() {
        let found = ConflictText.blocks(in: editor.textView.string)
        if found != blocks { blocks = found }
        editor.highlight(blocks)
        updateCaret()
    }

    private func updateCaret() {
        let inside = editor.block(atCaretIn: blocks)
        if inside != caretBlock { caretBlock = inside }
    }

    func resolve(_ choice: ConflictBlock.Choice) {
        guard let index = caretBlock, index < blocks.count else { NSSound.beep(); return }
        let label = editor.resolve(blocks[index], choice)
        // On to the next block, as the merge view is for going through them: by the blocks as
        // they are now (the editor's change notice can come later, and the old ranges put the
        // caret between blocks, so a quick second ⌘1 only beeped).
        update()
        if !blocks.isEmpty { editor.go(forward: true, in: blocks) }
        // Said, as the header is drawn (F60): what was kept, and what's left or how to finish.
        Announce.sentence(blocks.isEmpty ? Document.resolvedSaid(choice, label: label, left: 0) + " All conflicts resolved. Command-Return finishes."
                                         : Document.resolvedSaid(choice, label: label, left: blocks.count))
    }
}

struct MergeView: View {
    let document: Document
    let session: MergeSession

    static let minimum = CGSize(width: 600, height: 420)

    /// 900×640, or what the window has room for, 20 points in from each side.
    private var idealSize: CGSize {
        let room = document.editor.textView.window?.contentLayoutRect.size ?? CGSize(width: 900, height: 640)
        return CGSize(width: max(Self.minimum.width, min(900, room.width - 40)), height: max(Self.minimum.height, min(640, room.height - 40)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hudText(header, glyphSize: 9)
                .font(HUDFont.label(10))
                .foregroundStyle(session.blocks.isEmpty ? HUDColor.bright : HUDColor.failureText)
                .accessibilityLabel(session.blocks.isEmpty ? "All conflicts resolved" : "\(session.blocks.count) conflicts left")
            HStack(spacing: 10) {
                HUDBox(title: session.first.label) { SidePane(text: session.first.text, marks: session.marks.first) }
                HUDBox(title: session.second.label) { SidePane(text: session.second.text, marks: session.marks.second) }
            }
            .frame(minHeight: 120, idealHeight: 210)
            HUDBox(title: "RESULT (EDITABLE)") { EditorHost(editor: session.editor) }
                .frame(minHeight: 150, idealHeight: 240)
            HStack(spacing: 12) {
                Text("⌥⌘↓ next conflict · ⌘1 ⌘2 use a version · ⌘3 keep both")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { document.closeMerge(done: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { document.closeMerge(done: true) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
        // No bigger than the window it's on: its minimum was 760×560, the window's 480×320, and the
        // sheet hung past it (the QA review's F58). Opening it grows a smaller window to fit.
        .frame(minWidth: Self.minimum.width, idealWidth: idealSize.width, minHeight: Self.minimum.height, idealHeight: idealSize.height)
        .background(Color(nsColor: Scheme.background))
        .onAppear { session.cancel = { document.closeMerge(done: false) } }
    }

    /// HUD grammar (W5, W6): what's merged and what's left, then what finishes.
    private var header: String {
        let name = document.url.lastPathComponent.uppercased()
        let left = session.blocks.count
        if left == 0 { return "NIB://MERGE · \(name) · ALL CONFLICTS RESOLVED · ⌘↩ TO FINISH" }
        return "NIB://MERGE · \(name) · \(left) CONFLICT\(left == 1 ? "" : "S") · \(session.total - min(left, session.total)) RESOLVED"
    }
}

/// A boxed panel with a pixel title on its top border, as Blit's expanded HUD draws them (V12).
struct HUDBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.top, 10)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(HUDColor.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(" \(title) ")
                    .font(HUDFont.label(9))
                    .foregroundStyle(Color(nsColor: Scheme.legible(NSColor(HUDColor.dim), on: Scheme.background)))   // F59: 4.1:1
                    .background(Color(nsColor: Scheme.background))
                    .offset(x: 10, y: -6)
            }
            .padding(.top, 6)
    }
}

/// One version, read-only: each line with its mark in a gutter column (~ changed, + only
/// here), tinted with An Old Hope's own diff colors, so color never carries it alone (V4).
struct SidePane: NSViewRepresentable {
    let text: String
    let marks: [ConflictText.LineMark]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = Scheme.background
        let view = NSTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isRichText = true
        view.backgroundColor = Scheme.background
        view.textContainerInset = NSSize(width: 4, height: 4)
        let (text, firstChange) = attributed()
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        // Open at the first difference, a few lines above it.
        DispatchQueue.main.async { view.reveal(firstChange, linesAbove: 3) }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    /// The text with its gutter column, and where the first marked line starts (a few lines up).
    private func attributed() -> (NSAttributedString, Int) {
        let out = NSMutableAttributedString()
        // Wrapped lines stay clear of the gutter column.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = ("~ " as NSString).size(withAttributes: [.font: Scheme.font]).width
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = [], firstChange: Int?
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1, line.isEmpty { break }   // the break after the last line
            let mark = i < marks.count ? marks[i] : .same
            starts.append(out.length)
            if mark != .same, firstChange == nil { firstChange = starts[max(0, starts.count - 4)] }
            let glyph = mark == .changed ? "~ " : mark == .only ? "+ " : "  "
            var body: [NSAttributedString.Key: Any] = [.font: Scheme.font, .foregroundColor: Scheme.foreground, .paragraphStyle: paragraph]
            if mark == .changed { body[.backgroundColor] = Scheme.markupChanged }
            if mark == .only { body[.backgroundColor] = Scheme.markupInserted }
            out.append(NSAttributedString(string: glyph, attributes: [.font: Scheme.font, .foregroundColor: Scheme.comment, .paragraphStyle: paragraph]))
            out.append(NSAttributedString(string: line + "\n", attributes: body))
        }
        return (out, firstChange ?? 0)
    }
}
