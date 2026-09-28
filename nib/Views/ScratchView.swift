// The scratch window (PRD §5.1): the text in An Old Hope, the status strip under it,
// and the conflict banner above it while the text holds conflict blocks (§5.4). Focus leaving the window saves (§4.3 step 3);
// focus arriving checks for a newer version (§4.4).

import AppKit
import NibSync
import SwiftUI

struct ScratchView: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if !document.blocks.isEmpty, !document.bannerHidden {
                ConflictBanner(document: document)
            }
            EditorHost(editor: document.editor)
            StatusStrip(document: document)
        }
        .background(Color(nsColor: OldHope.background))
        .navigationTitle(document.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .frame(minWidth: 480, minHeight: 320)
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

    /// "iCloud Drive › Nib › Test" (Nib's own folder) or "iCloud Drive › nib-spike", as Finder
    /// would name the folder.
    private var subtitle: String {
        let folder = document.url.deletingLastPathComponent().path
        for (root, name) in [(ScratchLocation.folder.path, "iCloud Drive › Nib"), (NibPaths.iCloudDrive.path, "iCloud Drive")]
        where folder == root || folder.hasPrefix(root + "/") {
            let rest = folder.dropFirst(root.count).split(separator: "/")
            return ([name] + rest.map(String.init)).joined(separator: " › ")
        }
        return (folder as NSString).abbreviatingWithTildeInPath
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
