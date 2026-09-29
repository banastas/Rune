// A document's window content (PRD §5.1): the text in An Old Hope, the status strip under
// it, and the conflict banner above it while the text holds conflict blocks (§5.4). Focus
// leaving the window saves (§4.3 step 3); focus arriving checks for a newer version (§4.4).
// The scratch window shows it alone; file windows (ED2) show it as native tabs together.

import AppKit
import NibSync
import SwiftUI

extension FocusedValues {
    /// The document of the window in front: what Save, Revert To and the Conflicts menu act on.
    @Entry var nibDocument: Document?
}

struct DocumentView: View {
    let document: Document

    var body: some View {
        VStack(spacing: 0) {
            if !document.blocks.isEmpty, !document.bannerHidden {
                ConflictBanner(document: document)
            }
            EditorHost(editor: document.editor)
            StatusStrip(document: document)
        }
        .background(Color(nsColor: Scheme.background))
        // The title bar shows the text's background through it; a light scheme's would put
        // the title in white on white, and the chrome stays dark anyway (A17): Nib's own dark.
        .toolbarBackground(Color(nsColor: Scheme.color(0x1C1D21)), for: .windowToolbar)
        .toolbarBackgroundVisibility(Scheme.theme.isLight ? .visible : .automatic, for: .windowToolbar)
        .navigationTitle(document.url.lastPathComponent)
        .navigationSubtitle(subtitle)
        .frame(minWidth: 480, minHeight: 320)
        .focusedSceneValue(\.nibDocument, document)
        .sheet(isPresented: Binding(get: { document.merge != nil }, set: { if !$0 { document.closeMerge(done: false) } })) {
            if let session = document.merge { MergeView(document: document, session: session) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard isOwnWindow(note.object) else { return }
            Task { await document.flush(reason: "window lost focus") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard isOwnWindow(note.object) else { return }
            Task { await document.fetchLatest(reason: "window focused") }
        }
    }

    private func isOwnWindow(_ object: Any?) -> Bool {
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

/// The scratch window (SC1): never a tab among files.
struct ScratchView: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DocumentView(document: document)
            .background(WindowConfigurator { $0.tabbingMode = .disallowed })
            .onAppear {
                AppDelegate.openScratchWindow = { openWindow(id: "scratch") }
                AppDelegate.openFileWindow = { openWindow(value: $0) }
            }
    }
}

/// A file's window (ED2): its document for as long as it's open, as a native tab beside the
/// other files' windows (A5, open question 11). Closing it saves, uploads and hands the file back.
struct FileWindow: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let document = Documents.document(for: url)
        DocumentView(document: document)
            .background(WindowConfigurator { window in
                // Closed, not just hidden behind another tab: save, upload, hand the file back.
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    Task { @MainActor in await Documents.close(document) }
                }
                window.tabbingIdentifier = "nib.file"
                window.tabbingMode = .preferred
                Self.joinTabs(window)
            })
            .onAppear { AppDelegate.openFileWindow = { openWindow(value: $0) } }
    }

    /// SwiftUI shows the window before it can be set up, so it joins the other files' tabs by
    /// hand, and again if AppKit ignored that while the window was still coming on screen.
    static func joinTabs(_ window: NSWindow, attempts: Int = 10) {
        guard attempts > 0 else { return }
        let host = NSApp.windows.first { $0 !== window && $0.tabbingIdentifier == "nib.file" && $0.isVisible }
        if window.isVisible {
            guard let host else { return }                                   // the first file window
            if host.tabGroup?.windows.contains(window) == true { return }  // joined
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { joinTabs(window, attempts: attempts - 1) }
    }
}

/// Runs once with the hosting NSWindow, when the view first lands in it (a tick after it's
/// made isn't enough: the view isn't always in a window yet, and then nothing ran).
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(configure) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private let configure: (NSWindow) -> Void
        private var done = false

        init(_ configure: @escaping (NSWindow) -> Void) {
            self.configure = configure
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window else { return }
            done = true
            configure(window)
        }
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
