// The conflict banner (PRD §5.4, §4.8 B): above the text while it holds conflict blocks,
// not a dialog (V8, V9). Native text with the muted-red tag (V3); it stays until every
// block is resolved, and Escape hides it until the blocks change. Resolve… goes to the
// next block (the merge view, §5.5, comes later).

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
            Button("Resolve…") { document.goToBlock(forward: true) }
                .help("Go to the next conflict (⌥⌘R)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: OldHope.lineHighlight))
        .overlay(alignment: .bottom) { Rectangle().fill(HUDColor.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        let n = document.blocks.count
        guard let other else { return n == 1 ? "1 conflict in this file, between markers." : "\(n) conflicts in this file, between markers." }
        if document.mergedAroundBlocks {
            return "\(other) and this Mac both changed \(n == 1 ? "1 place" : "\(n) places"). Everything else merged."
        }
        return "\(other) and this Mac both changed this file. Both versions are in the text, between markers."
    }

    /// Who the other side is, from the blocks' labels ("Air · 10:42" → "Air").
    private var other: String? {
        let labels = document.blocks.flatMap { [$0.firstLabel, $0.secondLabel] }
        let name = labels.first { !$0.hasPrefix(document.device) }?.components(separatedBy: " · ").first
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
