// First run (PRD AP5, §5.9): one window, three steps, native controls (V1). The scratch file,
// found or made (only once the user says so, so two Macs' first runs don't each make one), with
// what macOS may ask before it asks; the look, with Import from Sublime Text; the global
// shortcuts and Open Nib when you log in (AP2). Help › Welcome to Nib shows it again.

import AppKit
import NibSync
import NibText
import SwiftUI

@MainActor
@Observable
final class FirstRun: NSObject, NSWindowDelegate {
    enum Step: Int, CaseIterable {
        case scratch, look, keys

        var title: String {
            switch self {
            case .scratch: "Scratch File"
            case .look: "Look"
            case .keys: "Keys"
            }
        }
    }

    static let shared = FirstRun()
    static let doneKey = "firstRunDone"

    var step: Step = .scratch
    /// Whether the scratch file is there; nil while Nib looks (iCloud can take a few seconds
    /// to list Nib's folder on a Mac that's new to it).
    private(set) var scratchFound: Bool?
    /// A file chosen in place of the one open now, used once Nib reopens.
    private(set) var chosen: URL?
    private(set) var creating = false
    /// Why the last choice or creation didn't work, in a sentence.
    private(set) var message: String?
    /// What Import from Sublime Text would bring, or why there's nothing.
    private(set) var sublime: (found: String?, failure: String?) = (nil, nil)
    private(set) var imported = false
    @ObservationIgnored private(set) var window: NSWindow?

    /// Not yet done on this Mac. The scenarios never see it, but for their own.
    static var needed: Bool {
        #if DEBUG
        if let scenario = NibDefaults.store.string(forKey: "NibScenario") { return scenario == "firstrun" }
        #endif
        return NibDefaults.store.integer(forKey: doneKey) < 1
    }

    /// The scratch file is settled: there, or chosen.
    var scratchReady: Bool { chosen != nil || scratchFound == true }

    func show() {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        step = .scratch
        chosen = nil
        message = nil
        imported = false
        sublime = Schemes.shared.sublimePreview()
        wanted = 0
        let host = NSHostingController(rootView: FirstRunView(model: self))
        // The window follows each step's height, fitted by Nib after each change (`fit`). Left to
        // SwiftUI (`.preferredContentSize`), a warning appearing in step 3 resized the window inside
        // AppKit's layout pass, which looped until AppKit threw (a crash, 2026-10-07).
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: FirstRunView.width, height: FirstRunView.minHeight))
        window.title = "Welcome to Nib"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        Task { await look() }
    }

    /// The height the step needs, as last measured, with the footer.
    @ObservationIgnored private(set) var wanted: CGFloat = 0

    /// Fits the window to the step's height (no shorter than 580 points, no taller than the screen),
    /// on the next turn of the run loop, never inside a layout pass; its top edge stays put.
    func fit(_ height: CGFloat) {
        guard abs(height - wanted) >= 1 else { return }
        wanted = height
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            var content = max(FirstRunView.minHeight, self.wanted.rounded(.up))
            if let screen = window.screen ?? NSScreen.main {
                content = min(content, window.contentRect(forFrameRect: screen.visibleFrame).height)
            }
            let old = window.frame
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: FirstRunView.width, height: content)))
            guard abs(frame.height - old.height) >= 1 else { return }
            frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// Is the scratch file there? Nib's folder is asked for first, which sets it up on a new Mac.
    func look() async {
        let document = Documents.scratch
        if chosen == nil { scratchFound = nil }
        let url = scratchURL
        if ScratchLocation.inContainer(url) {
            _ = await CloudControl.containerAvailable(ScratchLocation.containerID, within: 10)
        }
        let exists = await Task.detached { FileManager.default.fileExists(atPath: url.path) }.value
        scratchFound = exists
        if exists, document.awaitingFirstRun { await document.open() }
        if !exists { keepLooking() }
    }

    @ObservationIgnored private var looking: Task<Void, Never>?

    /// Not there yet: looked for again every 2 s while the window's open, as another Mac's may be
    /// on its way. It looked once and offered Create, which on a second Mac made an empty one
    /// where the first Mac's was still coming (the QA review's F26).
    private func keepLooking() {
        looking?.cancel()
        looking = Task { [weak self] in
            while let self, !Task.isCancelled, self.window != nil, self.scratchFound == false, self.chosen == nil, !self.creating {
                try? await Task.sleep(for: .seconds(Self.lookEvery))
                let url = self.scratchURL
                guard await Task.detached(operation: { FileManager.default.fileExists(atPath: url.path) }).value, self.scratchFound == false else { continue }
                self.scratchFound = true
                if Documents.scratch.awaitingFirstRun { await Documents.scratch.open() }
            }
        }
    }

    static var lookEvery: Double = 2

    #if DEBUG
    /// The `firstrun` scenario: a scratch file to look for that isn't there yet.
    static var lookingFor: URL?
    #endif

    private var scratchURL: URL {
        #if DEBUG
        if let url = Self.lookingFor { return url }
        #endif
        return Documents.scratch.url
    }

    /// Makes the scratch file where Nib looked: opening it creates it, empty.
    func create() async {
        let document = Documents.scratch
        guard document.awaitingFirstRun else { await look(); return }
        creating = true
        message = nil
        await document.open()
        creating = false
        scratchFound = FileManager.default.fileExists(atPath: document.url.path)
        if scratchFound != true { message = "Nib couldn't make it. \(Spoken.sentence(document.state.line))." }
    }

    func choose() {
        if let url = ScratchChoice.ask() { use(url) }
    }

    /// Another file as the scratch file, if Nib may open it (§8).
    func use(_ url: URL) {
        message = ScratchChoice.refusal(url)
        guard message == nil else { return }
        let same = ScratchChoice.isCurrent(url)
        chosen = same ? nil : url
        if same { Task { await look() } }
    }

    func keepCurrent() {
        chosen = nil
        message = nil
    }

    func importSublime() {
        Schemes.shared.importFromSublime()
        imported = true
    }

    /// Done: the scratch window, or Nib reopened with the chosen file; and macOS asks whether
    /// Nib may send its notifications, as step 3 said it would (AP5).
    func finish() {
        NibDefaults.store.set(1, forKey: Self.doneKey)
        Notifier.shared.askIfNeeded()
        let chosen = chosen
        window?.close()
        guard let chosen else { AppDelegate.showScratch(); return }
        ScratchChoice.use(chosen)
    }

    func windowWillClose(_ notification: Notification) {
        // Closed before the end: done if the scratch file is settled, or it comes back next
        // time (and the scratch window's strip says where to look).
        if scratchFound == true, chosen == nil {
            NibDefaults.store.set(1, forKey: Self.doneKey)
            Notifier.shared.askIfNeeded()
        }
        looking?.cancel()
        window = nil
    }
}

/// Another scratch file (SC1), from the first run or Settings › Scratch & Sync: Nib reopens with it,
/// having handed the old one back to iCloud. The old file stays where it is.
@MainActor
enum ScratchChoice {
    static func ask() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the file to use as your scratch file."
        panel.prompt = "Use as Scratch"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Documents.scratch.url.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Why Nib won't use it, in a sentence (the safety rule, §8).
    static func refusal(_ url: URL) -> String? {
        guard ScratchLocation.refusal(for: url) != nil else { return nil }
        return "In a test run, Nib opens only test files, in iCloud Drive › Nib › Test. \(url.lastPathComponent) isn't one."
    }

    static func isCurrent(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path == Documents.scratch.url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func use(_ url: URL) {
        if url.standardizedFileURL.path == ScratchLocation.standardURL.standardizedFileURL.path {
            NibDefaults.store.removeObject(forKey: "scratchPath")
        } else {
            NibDefaults.store.set(url.path, forKey: "scratchPath")
        }
        AppDelegate.relaunch()
    }
}

struct FirstRunView: View {
    let model: FirstRun

    static let width: CGFloat = 560
    static let minHeight: CGFloat = 580
    @State private var stepHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Form {
                    switch model.step {
                    case .scratch: ScratchStep(model: model)
                    case .look: LookStep(model: model)
                    case .keys: KeysStep(model: model)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            // As tall as its step, whatever the window's height (a fixed 580 cut off its own notes,
            // the QA review's F22), measured for `FirstRun.fit`.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { stepHeight = $0; model.fit(stepHeight + footerHeight) }
            Spacer(minLength: 0)
            footer
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0; model.fit(stepHeight + footerHeight) }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Step \(model.step.rawValue + 1) of \(FirstRun.Step.allCases.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                if model.step != .scratch {
                    Button("Back") { model.step = FirstRun.Step(rawValue: model.step.rawValue - 1) ?? .scratch }
                }
                if model.step == .keys {
                    Button(model.chosen == nil ? "Done" : "Reopen Nib") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.step = FirstRun.Step(rawValue: model.step.rawValue + 1) ?? .keys }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.step == .scratch && !model.scratchReady)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Nib").font(.title2.weight(.semibold))
                    Text("Three things to set up. Each can be changed later in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                ForEach(FirstRun.Step.allCases, id: \.self) { step in
                    let current = step == model.step
                    let past = step.rawValue < model.step.rawValue
                    HStack(spacing: 6) {
                        Image(systemName: past ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle\(current ? ".fill" : "")")
                            .foregroundStyle(current || past ? Color.accentColor : .secondary)
                        Text(step.title)
                            .fontWeight(current ? .semibold : .regular)
                            .foregroundStyle(current ? .primary : .secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(step.rawValue + 1), \(step.title)\(current ? ", current" : past ? ", done" : "")")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }
}

/// Step 1: where the scratch file is, or making it; and what macOS may ask.
private struct ScratchStep: View {
    let model: FirstRun

    var body: some View {
        let current = Documents.scratch.url
        let name = current.lastPathComponent
        let place = ScratchLocation.place(of: current)
        Section("Where's your scratch file?") {
            Group {
                if let chosen = model.chosen {
                    Label("Nib will use \(chosen.lastPathComponent) in \(ScratchLocation.place(of: chosen)) once it reopens, at the end.",
                          systemImage: "arrow.triangle.2.circlepath")
                } else if model.scratchFound == nil {
                    Label { Text("Looking in \(place)…") } icon: { ProgressView().controlSize(.small) }
                } else if model.scratchFound == true {
                    Label { Text("Found \(name) in \(place).") } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                } else {
                    // Said as maybe on its way, and looked for while this window's open (F26).
                    Label("There's no \(name) in \(place) yet. If another Mac has one, iCloud may still be bringing it: Nib keeps looking while this window is open.",
                          systemImage: "doc.badge.plus")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.chosen != nil {
                    Button("Keep \(name)") { model.keepCurrent() }
                } else if model.scratchFound == false {
                    Button("Create “\(name)”") { Task { await model.create() } }
                        .disabled(model.creating)
                } else if model.scratchFound == true {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([current]) }
                }
                Button(model.scratchFound == false && model.chosen == nil ? "Choose…" : "Choose Another…") { model.choose() }
                    .disabled(model.scratchFound == nil)
            }
            if let message = model.message {
                Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.failure)
                }
            }
            // What it says of the file that will be used: one chosen outside iCloud Drive stays on this
            // Mac (the QA review's F28: it said every Mac whatever was chosen).
            if let chosen = model.chosen, !ScratchLocation.place(of: chosen).hasPrefix("iCloud Drive") {
                firstRunNote("The scratch file is where everything you jot down goes. \(chosen.lastPathComponent) is on this Mac only, so your other Macs won't see it: choose one in iCloud Drive to have it on every Mac.")
            } else {
                firstRunNote("The scratch file is where everything you jot down goes. It's in Nib's own folder in iCloud Drive, so every Mac signed in to your Apple Account opens the same file, and Nib keeps them the same. If one Mac already has it, this finds it; make it only on the first Mac.")
            }
            // §4.9 row 7: macOS has no way for an app to keep one file on the Mac (M0 checked).
            firstRunNote("So that macOS never takes it off this Mac to free up space, Control-click iCloud Drive › Nib in Finder and choose Keep Downloaded. If it's off this Mac anyway, Nib brings it back when it opens, or shows the last copy it saw while you're offline.")
            if ScratchLocation.safetyRule {
                firstRunNote("In a test run, Nib opens only test files, in iCloud Drive › Nib › Test, so this is its test file.")
            }
        }
        Section("What macOS may ask") {
            firstRunNote("Nothing, for Nib's own iCloud Drive folder, and nothing for its global shortcuts, which need no Accessibility access. If you choose a scratch file in Documents, on the Desktop or elsewhere in iCloud Drive, macOS may ask once whether Nib can open files there: Nib only opens the files you choose. If you have Nib open when you log in (the last step), macOS says so in a notification.")
        }
    }
}

/// Step 2: the color scheme Nib uses, and Import from Sublime Text.
private struct LookStep: View {
    let model: FirstRun

    var body: some View {
        let schemes = Schemes.shared
        Section("Look") {
            Text("Nib uses \(schemes.current.name), in \(schemes.fontFace.isEmpty ? "SF Mono" : schemes.fontFace) \(schemes.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt, and it's always dark.")
                .fixedSize(horizontal: false, vertical: true)
        }
        Section("Your Sublime Text settings") {
            if let found = model.sublime.found {
                if model.imported, let report = schemes.report {
                    Text("Imported:")
                    hudBlock(report)
                } else {
                    Text("Use Sublime's color scheme, font and editor settings? Sublime Text has:")
                    hudBlock(found)
                    Button("Import from Sublime Text") { model.importSublime() }
                }
                // Everything it sets, as Settings › Themes says too (the QA review's F25: it listed five).
                firstRunNote("Import takes Sublime's color scheme, font and size, tab width and spaces, line numbers, invisibles, indent guides, matching brackets, closing pairs and ⌘S tidying, and sets Nib's to match. Sublime's files are only read, never changed. \(model.imported ? "" : "Continue skips it; ")Settings › Themes can import later.")
            } else {
                Text(model.sublime.failure ?? "")
                    .fixedSize(horizontal: false, vertical: true)
                firstRunNote("Settings › Themes can import a .tmTheme or .sublime-color-scheme file later, and Settings › Editor has the font.")
            }
        }
    }

    private func hudBlock(_ text: String) -> some View {
        Text(text)
            .font(HUDFont.terminal(15))
            .foregroundStyle(HUDColor.bright)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUDColor.background)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(HUDColor.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(text.lowercased())
    }
}

/// Step 3: the two global shortcuts, Open Nib when you log in, and what macOS will ask about
/// notifications when this is done (AP5, SY15).
private struct KeysStep: View {
    let model: FirstRun

    var body: some View {
        Section("Global shortcuts") {
            ShortcutRow(action: .showScratch)
            ShortcutRow(action: .cleanClipboard)
            firstRunNote("They work from any app. Show Scratch brings the scratch window forward, and pressed again goes back to the app you were in. Clean Clipboard makes what you copied plain text, in place. Click one and press new keys; Settings › General has them too.")
        }
        Section {
            LoginToggle()
        }
        Section("Notifications") {
            firstRunNote("When Nib is in the background, it tells you about a conflict, a file it can't save or sync, or one deleted or moved to the Trash, with a notification and a sound. Nothing else: not saves, not syncs. macOS asks whether Nib may when you click \(model.chosen == nil ? "Done" : "Reopen Nib"); System Settings › Notifications changes it later.")
        }
    }
}

/// Open Nib when you log in (AP2), with what macOS says about it.
struct LoginToggle: View {
    var body: some View {
        let login = LoginItem.shared
        Toggle("Open Nib when you log in", isOn: Binding(get: { login.enabled || login.needsApproval }, set: { login.set($0) }))
            .onAppear { login.refresh() }
        if login.needsApproval {
            HStack {
                Text("macOS is waiting for your OK in System Settings › General › Login Items.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items") { login.openSystemSettings() }
            }
        }
        if let failure = login.failure {
            Label { Text(failure).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.failure)
            }
        }
        firstRunNote("So Show Scratch works from the moment you log in. macOS confirms it in a notification and lists Nib in System Settings › General › Login Items, where you can turn it off too.")
    }
}

private func firstRunNote(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}
