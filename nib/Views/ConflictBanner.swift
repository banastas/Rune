// The conflict banner (PRD §5.4, §4.8 B): above the text while it holds conflict blocks,
// not a dialog (V8, V9). Native text with the muted-red tag (V3); it stays until every
// block is resolved, and Escape hides it until the blocks change. Its button goes to the next
// block, or with more than three opens the merge view (§5.5), and is named for which.

import NibText
import SwiftUI

struct ConflictBanner: View {
    let document: Document

    var body: some View {
        HStack(spacing: 10) {
            hudText("✕ CONFLICT", glyphSize: 9)
                .font(HUDFont.label(9))
                .foregroundStyle(HUDColor.onFailure)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(HUDColor.failure)
                .fixedSize()
                .accessibilityLabel("Conflict")
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                Text("In a block, ⌘1 or ⌘2 uses that version, ⌘3 keeps both.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .lineLimit(2)
            Spacer(minLength: 8)
            // Named for what it does (F52): the next block with three or fewer, else the merge view.
            Button(document.blocks.count > 3 ? "Merge View…" : "Next Conflict") { document.resolveConflicts() }
                .help(document.blocks.count > 3 ? "Open the merge view (⌥⌘R)" : "Go to the next conflict (⌥⌘↓); the merge view is ⌥⌘R")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: Scheme.lineHighlight))
        .overlay(alignment: .bottom) { Rectangle().fill(HUDColor.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private var message: String { Self.message(blocks: document.blocks.count, others: others, merged: document.mergedAroundBlocks,
                                               fileExtension: document.url.pathExtension) }

    /// The banner's sentence, from who the other sides are. It took the first label not starting
    /// with this Mac's name: "This Mac and this Mac both changed this file", "The file and this
    /// Mac…" after a crash, and a Mac named "Studio 2" taken for "Studio" (the QA review's F10).
    static func message(blocks n: Int, others: [String], merged: Bool, fileExtension: String) -> String {
        let between = n == 1 ? "1 conflict in this file, between markers." : "\(n) conflicts in this file, between markers."
        guard let other = others.first else { return between }
        if others.count > 1 { return "Several versions changed this file. \(between.prefix(1).uppercased() + between.dropFirst())" }
        if other == "The file" {
            return "The file changed while Nib was closed. It and the typing Nib recovered are both in the text, between markers."
        }
        if other == "Merge view" {
            return "The merge view's choices and the typing since both changed this file. Both versions are in the text, between markers."
        }
        if !fileExtension.isEmpty, other.hasSuffix("." + fileExtension) {
            return "\(Alerts.quoted(other)) is a copy of this file with other text. Both versions are in the text, between markers."   // F64
        }
        let who = other.prefix(1).uppercased() + other.dropFirst()   // "another Mac" begins the sentence
        if merged { return "\(who) and this Mac both changed \(n == 1 ? "1 place" : "\(n) places"). Everything else merged." }
        return "\(who) and this Mac both changed this file. Both versions are in the text, between markers."
    }

    /// The other sides, from the blocks' labels ("Air · 10:42" → "Air"), whole names compared
    /// with this Mac's, each once.
    private var others: [String] { Self.others(document.blocks.flatMap { [$0.firstLabel, $0.secondLabel] }, device: document.device) }

    static func others(_ labels: [String], device: String) -> [String] {
        var names: [String] = []
        for label in labels {
            let name = (label.components(separatedBy: " · ").first ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != device, name.caseInsensitiveCompare("This Mac") != .orderedSame, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}
