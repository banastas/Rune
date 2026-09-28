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
    @ObservationIgnored let editor = Editor()
    private(set) var blocks: [ConflictBlock] = []
    private(set) var caretBlock: Int?
    /// Set by the sheet: Escape in the result cancels.
    @ObservationIgnored var cancel: (() -> Void)?

    var result: String { editor.textView.string }

    init(text: String, device: String, syntax: (language: SyntaxLanguage, root: String)?) {
        original = text
        let found = ConflictText.blocks(in: text)
        let sides = ConflictText.sides(of: text)
        first = .init(text: sides.first, label: Self.title(found.first?.firstLabel ?? "First", device: device))
        second = .init(text: sides.second, label: Self.title(found.first?.secondLabel ?? "Second", device: device))
        let marks = ConflictText.lineMarks(sides.first, sides.second)
        self.marks = (marks.a, marks.b)
        total = found.count
        editor.textView.string = text
        editor.syntax = syntax
        editor.textView.setAccessibilityLabel("Merge result")
        editor.onChange = { [weak self] in self?.update() }
        editor.onSelection = { [weak self] in self?.updateCaret() }
        editor.textView.onEscape = { [weak self] in self?.cancel?(); return true }
        editor.textView.setSelectedRange(NSRange(location: found.first?.first.location ?? 0, length: 0))
        update()
    }

    /// "Air · 10:42" → "AIR · 10:42", or "AIR · THIS MAC · 10:42" for this Mac's side.
    static func title(_ label: String, device: String) -> String {
        var parts = label.components(separatedBy: " · ")
        if parts.first == device { parts.insert("This Mac", at: 1) }
        return parts.joined(separator: " · ").uppercased()
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
        editor.resolve(blocks[index], choice)
        // On to the next block, as the merge view is for going through them.
        if !blocks.isEmpty { editor.go(forward: true, in: blocks) }
    }
}

struct MergeView: View {
    let document: Document
    let session: MergeSession

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
            .frame(minHeight: 150, idealHeight: 210)
            HUDBox(title: "RESULT (EDITABLE)") { EditorHost(editor: session.editor) }
                .frame(minHeight: 180, idealHeight: 240)
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
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560, idealHeight: 640)
        .background(Color(nsColor: OldHope.background))
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
                    .foregroundStyle(HUDColor.dim)
                    .background(Color(nsColor: OldHope.background))
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
        scroll.backgroundColor = OldHope.background
        let view = NSTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isRichText = true
        view.backgroundColor = OldHope.background
        view.textContainerInset = NSSize(width: 4, height: 4)
        let (text, firstChange) = attributed()
        view.textStorage?.setAttributedString(text)
        scroll.documentView = view
        // Open at the first difference, a few lines above it.
        DispatchQueue.main.async {
            view.scrollRangeToVisible(NSRange(location: text.length, length: 0))
            view.scrollRangeToVisible(NSRange(location: firstChange, length: 0))
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    /// The text with its gutter column, and where the first marked line starts (a few lines up).
    private func attributed() -> (NSAttributedString, Int) {
        let out = NSMutableAttributedString()
        // Wrapped lines stay clear of the gutter column.
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = ("~ " as NSString).size(withAttributes: [.font: OldHope.font]).width
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var starts: [Int] = [], firstChange: Int?
        for (i, line) in lines.enumerated() {
            if i == lines.count - 1, line.isEmpty { break }   // the break after the last line
            let mark = i < marks.count ? marks[i] : .same
            starts.append(out.length)
            if mark != .same, firstChange == nil { firstChange = starts[max(0, starts.count - 4)] }
            let glyph = mark == .changed ? "~ " : mark == .only ? "+ " : "  "
            var body: [NSAttributedString.Key: Any] = [.font: OldHope.font, .foregroundColor: OldHope.foreground, .paragraphStyle: paragraph]
            if mark == .changed { body[.backgroundColor] = OldHope.markupChanged }
            if mark == .only { body[.backgroundColor] = OldHope.markupInserted }
            out.append(NSAttributedString(string: glyph, attributes: [.font: OldHope.font, .foregroundColor: OldHope.comment, .paragraphStyle: paragraph]))
            out.append(NSAttributedString(string: line + "\n", attributes: body))
        }
        return (out, firstChange ?? 0)
    }
}
