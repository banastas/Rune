// The scratch window (PRD §5.1): the text in An Old Hope, the status strip under it,
// and the conflict sheet when there is one. Focus leaving the window saves (§4.3 step 3);
// focus arriving checks for a newer version (§4.4).

import AppKit
import NibSync
import SwiftUI

struct ScratchView: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            EditorHost(editor: document.editor)
            StatusStrip(document: document)
        }
        .background(Color(nsColor: OldHope.background))
        .navigationTitle(document.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .frame(minWidth: 480, minHeight: 320)
        // Only a resolution clears a conflict; the sheet can't be dismissed without one.
        .sheet(item: Binding(get: { document.conflict }, set: { _ in })) { conflict in
            ConflictSheet(document: document, conflict: conflict)
                .interactiveDismissDisabled()
        }
        .onAppear { AppDelegate.openScratchWindow = { openWindow(id: "scratch") } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isScratchWindow(note.object) else { return }
            Task { await document.flush(reason: "window lost focus") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard isScratchWindow(note.object) else { return }
            Task { await document.fetchLatest(reason: "window focused") }
        }
    }

    private func isScratchWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow else { return false }
        return window === document.editor.textView.window
    }

    /// "iCloud Drive › nib-spike", as Finder would name the folder.
    private var subtitle: String {
        let folder = document.url.deletingLastPathComponent().path
        let drive = NibPaths.iCloudDrive.path
        guard folder.hasPrefix(drive) else { return (folder as NSString).abbreviatingWithTildeInPath }
        let rest = folder.dropFirst(drive.count).split(separator: "/")
        return (["iCloud Drive"] + rest.map(String.init)).joined(separator: " › ")
    }
}

/// The document's own scroll view, so the buffer outlives the window.
struct EditorHost: NSViewRepresentable {
    let editor: Editor

    func makeNSView(context: Context) -> NSScrollView {
        DispatchQueue.main.async { editor.textView.window?.makeFirstResponder(editor.textView) }
        return editor.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
