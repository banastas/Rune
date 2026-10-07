// A document's window content (PRD §5.1): the text in An Old Hope, the status strip under
// it, the find bar over the strip while it's open (ED7), the sync HUD over the text's foot
// while it's open (§5.3), and the conflict banner above the text while the text holds
// conflict blocks (§5.4), or the deleted banner while its file is gone (§4.8 E). Focus
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if document.deleted {
                DeletedBanner(document: document)
            } else if !document.blocks.isEmpty, !document.bannerHidden {
                ConflictBanner(document: document)
            }
            EditorHost(editor: document.editor)
                // The sync HUD (§5.3), opening upward from the strip over the text.
                .overlay(alignment: .bottom) {
                    if document.syncDetailsShown {
                        SyncHUD(document: document)
                            .padding(8)
                            .transition(.crt(reduceMotion: reduceMotion))
                    }
                }
                .animation(.crt, value: document.syncDetailsShown)
            if document.editor.find.shown { FindBar(find: document.editor.find) }
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
        // Go to File and the command palette (KB2, KB3): what was chosen runs once it's gone.
        .sheet(item: Binding(get: { document.palette }, set: { document.palette = $0 }),
               onDismiss: { document.finishPalette() }) { session in
            CommandPalette(entries: session.entries, prompt: session.prompt, extra: session.lineEntry,
                           empty: session.empty, initial: session.initial) { session.choose($0) }
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

    /// "iCloud Drive › Nib › Test", as Finder would name the folder.
    private var subtitle: String {
        document.untitled ? "On this Mac only" : ScratchLocation.place(of: document.url)
    }
}

/// The scratch window (SC1): a tab among the files' (A5, the user's call, 2026-10-02: one window,
/// as Sublime's), brought forward with its tab by Show Scratch. ⌘W closes it; Show Scratch and
/// the Dock bring it back, a tab again.
struct ScratchView: View {
    let document: Document
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DocumentView(document: document)
            .background(WindowConfigurator { window in
                window.tabbingIdentifier = "nib.file"
                window.tabbingMode = .preferred
                FileWindow.joinTabs(window)
                #if DEBUG
                AppDelegate.launchMoments.window = AppDelegate.launchMoments.window ?? Date()   // §6.5's cold launch
                #endif
            })
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
    /// Its document, got once as it first appears. Got in `body`, a redraw as the window closed
    /// made a new one for the file just let go and opened it again, held, with no window (the
    /// `files` scenario, 2026-10-02: an untitled tab's file stayed behind).
    @State private var document: Document?

    var body: some View {
        ZStack {
            if let document {
                DocumentView(document: document)
                    .background(WindowConfigurator { window in
                        // Closing it saves, uploads and hands the file back (`Documents.watchClosing`).
                        window.tabbingIdentifier = "nib.file"
                        window.tabbingMode = .preferred
                        Self.joinTabs(window)
                    })
            } else {
                Color(nsColor: Scheme.background)   // a moment, till its document is got (empty, it never appeared)
            }
        }
        .onAppear {
            if document == nil { document = Documents.document(for: url) }
            AppDelegate.openFileWindow = { openWindow(value: $0) }
        }
    }

    /// The window New and New Tab were chosen in: their tab goes there, if it takes tabs.
    static weak var tabHost: NSWindow?

    /// SwiftUI shows the window before it can be set up, so it joins the other files' tabs by
    /// hand, and again if AppKit ignored that while the window was still coming on screen: the
    /// window New was chosen in, else the first that takes them (the scratch window's too).
    static func joinTabs(_ window: NSWindow, attempts: Int = 10) {
        guard attempts > 0 else { return }
        let chosen = tabHost.flatMap { $0 !== window && $0.tabbingIdentifier == "nib.file" && $0.isVisible ? $0 : nil }
        let host = chosen ?? NSApp.windows.first { $0 !== window && $0.tabbingIdentifier == "nib.file" && $0.isVisible }
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
