// M1's conflict safety net (PRD SY6): the file changed while there were unsaved
// edits. Both versions side by side; Keep Mine, Keep Theirs or Keep Both. Nothing is
// overwritten while it waits. M2 replaces this with the three-way merge (§4.7-4.8).

import AppKit
import NibText
import SwiftUI

struct ConflictSheet: View {
    let document: Document
    let conflict: Conflict

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(document.url.lastPathComponent)” changed while you had unsaved edits")
                .font(.headline)
            Text("Nothing has been overwritten. The file holds the other version; your edits are here and in nib's recovery journal. Keep Both puts the lines that differ one after the other, between conflict markers, so you can tidy them up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                pane(conflict.mine, other: conflict.theirs.text)
                pane(conflict.theirs, other: conflict.mine.text)
            }
            HStack {
                Spacer()
                Button("Keep Theirs") { document.resolve(.theirs) }
                Button("Keep Mine") { document.resolve(.mine) }
                Button("Keep Both") { document.resolve(.both) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 460, idealHeight: 560)
    }

    private func pane(_ side: ConflictText.Side, other: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(side.label.uppercased())
                .font(HUDFont.label())
                .foregroundStyle(.secondary)
            ReadOnlyText(text: side.text, scrollTo: firstDifference(side.text, other))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    /// Where the two versions start to differ, so each pane opens there.
    private func firstDifference(_ a: String, _ b: String) -> Int {
        let x = a as NSString, y = b as NSString
        let n = min(x.length, y.length)
        var i = 0
        while i < n, x.character(at: i) == y.character(at: i) { i += 1 }
        return i
    }
}

/// A read-only text view in the editor's colors, for the conflict sheet.
struct ReadOnlyText: NSViewRepresentable {
    let text: String
    let scrollTo: Int

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = NSTextView(usingTextLayoutManager: true)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isRichText = false
        view.font = OldHope.font
        view.textColor = OldHope.foreground
        view.backgroundColor = OldHope.background
        view.textContainerInset = NSSize(width: 8, height: 6)
        view.string = text
        scroll.documentView = view
        DispatchQueue.main.async {
            let location = min(scrollTo, (text as NSString).length)
            view.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
