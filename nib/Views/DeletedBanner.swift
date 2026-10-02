// The deleted banner (PRD §4.8 E, §4.9 8): above the text while its file is gone, deleted or
// moved to the Trash by another app. As the conflict banner is, not a dialog (V8, V9): the text
// stays and can be typed in, and nothing makes the file again until Restore. Close keeps the
// text in History, on File › Reopen Closed File; the scratch file has Restore only. When the
// file went with iCloud Drive (§4.9 11), no Restore: it's saved to Nib's Recovery folder, and
// goes back into the file when iCloud Drive is on again.

import AppKit
import NibText
import SwiftUI

struct DeletedBanner: View {
    let document: Document

    var body: some View {
        HStack(spacing: 10) {
            hudText(document.iCloudOff ? "✕ ICLOUD OFF" : document.deletedToTrash ? "✕ IN THE TRASH" : "✕ DELETED", glyphSize: 9)
                .font(HUDFont.label(9))
                .foregroundStyle(HUDColor.onFailure)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(HUDColor.failure)
                .fixedSize()
                .accessibilityLabel(document.iCloudOff ? "iCloud off" : document.deletedToTrash ? "In the Trash" : "Deleted")
            VStack(alignment: .leading, spacing: 2) {
                if document.iCloudOff {
                    Text("iCloud Drive is off on this Mac, and \(document.url.lastPathComponent) went with it.")
                    Text("Your text is saved in Nib's Recovery folder, and goes back into the file when iCloud Drive is on again.")
                        .foregroundStyle(.secondary)
                } else {
                    // A move to this Mac's Trash is this Mac's; a deletion may be another Mac's too, which
                    // arrives as a deletion, its Trash being its own (the two-Mac probe, 2026-10-01).
                    Text("\(document.url.lastPathComponent) was \(document.deletedToTrash ? "moved to the Trash by another app." : "deleted, by another app or on another Mac.")")
                    Text("Your text is still here, and in Nib's journal. Nothing makes the file again until you restore it.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(2)
            Spacer(minLength: 8)
            if document !== Documents.scratch {
                Button("Close") { document.editor.textView.window?.performClose(nil) }
                    .help("Close it: the text stays in History, on File › Reopen Closed File")
            }
            if document.iCloudOff {
                Button("Show in Finder") {
                    let copy = document.recoveryURL
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: copy.path) ? copy : copy.deletingLastPathComponent()])
                }
                .help("Show the text's copy in Nib's Recovery folder")
            } else {
                Button("Restore") { Task { await document.restoreDeleted() } }
                    .help("Write the text back where the file was")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: Scheme.lineHighlight))
        .overlay(alignment: .bottom) { Rectangle().fill(HUDColor.border).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
    }
}
