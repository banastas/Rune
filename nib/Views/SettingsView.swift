// Settings (PRD §5.8, V12, W7): tabs, grouped forms that size to fit, 480 pt wide, and a
// plain note under each control saying what it does and doesn't do. General (open at login,
// the global shortcuts and Paste Clean, the menu bar extra and the Dock), Scratch & Sync (the
// scratch file, saving, this Mac's name, notifications, History), Files (the kinds of file a
// double-click opens in Nib), Editor (the font and size, indentation, what's drawn beside the
// text, ⌘S tidying) and Themes (the scheme, Import from Sublime Text, Import File…, and the last
// import's report, HL2-HL4). Each tab fits the Air's screen, as Settings can't scroll (F22).

import AppKit
import NibText
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab", store: NibDefaults.store) private var tab = "general"   // was "editor": Settings opened on its third tab (F84)

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            SyncSettings()
                .tabItem { Label("Scratch & Sync", systemImage: "icloud") }
                .tag("sync")
            FileSettings()
                .tabItem { Label("Files", systemImage: "doc.on.doc") }
                .tag("files")
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
                .tag("editor")
            ThemeSettings()
                .tabItem { Label("Themes", systemImage: "paintpalette") }
                .tag("themes")
        }
        .frame(width: 480)
        .fixedSize()
    }
}

/// Settings › General: open at login (AP2), the global shortcuts (SC2, PT4, SC6) and what Paste
/// Clean and they do to text (PT3), the menu bar extra (AP3) and the Dock icon (AP6). Short enough
/// for the Air's screen: it was 967 points tall with the scratch file in it, and can't scroll (the
/// QA review's F22); Paste Clean came here from Editor, which was 989.
private struct GeneralSettings: View {
    @AppStorage("showMenuBarExtra", store: NibDefaults.store) private var showMenuBarExtra = true
    @AppStorage("hideDockIcon", store: NibDefaults.store) private var hideDockIcon = false
    @AppStorage("pasteStraightensQuotes", store: NibDefaults.store) private var straightenQuotes = false

    var body: some View {
        Form {
            Section {
                LoginToggle()
            }
            Section("Global shortcuts") {
                ForEach(GlobalShortcuts.Action.allCases) { ShortcutRow(action: $0) }
                note("They work from any app, and need no Accessibility access. Click one and press the new keys: with ⌃, or ⌘ and ⌥, or a function key, as keys other apps use for themselves can't be taken. Delete clears it; Escape keeps it.")
            }
            Section {
                Toggle("Paste Clean straightens quotes and dashes", isOn: $straightenQuotes)
                note("Paste Clean (⌥⇧⌘V), Clean Clipboard, Append Clipboard to Scratch, the Services and nib -a always remove invisible characters, make odd spaces plain and trim trailing spaces. With this on they also straighten “curly” quotes, dashes and …. ⌘V pastes text as it is.")
            }
            Section {
                Toggle("Show Nib in the menu bar", isOn: $showMenuBarExtra)
                    .disabled(hideDockIcon && showMenuBarExtra)   // with no Dock icon, the way to Nib
                note("It shows how your open files sync: still when all's well, its line marching while an upload waits, a red ✕ when one needs a look. Click it for the scratch file, the clipboard commands and recent files.")
                Toggle("Show Nib in the Dock", isOn: Binding(get: { !hideDockIcon }, set: { hideDockIcon = !$0 }))
                    .disabled(!showMenuBarExtra && !hideDockIcon)
                note("Off, Nib is only in the menu bar: not in the Dock or ⌘Tab, and with no menu bar of its own. It can be off only while the nib in the menu bar is shown.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// Settings › Scratch & Sync (§5.8): the scratch file (SC1), how Nib saves, this Mac's name as
/// the other Macs see it, notifications (SY15) and History (the QA review's F48).
private struct SyncSettings: View {
    @State private var refusal: String?

    var body: some View {
        Form {
            Section("Scratch file") {
                let url = Documents.scratch.url
                LabeledContent(url.lastPathComponent, value: ScratchLocation.place(of: url))
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Change…") { change() }
                }
                if let refusal {
                    Label { Text(refusal).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.failure)
                    }
                }
                note((ScratchLocation.place(of: url).hasPrefix("iCloud Drive")
                      ? "It's in iCloud Drive, so every Mac signed in to your Apple Account opens the same file. "
                      : "It's on this Mac only, so your other Macs won't see it: choose one in iCloud Drive to have it on every Mac. ")
                     + "Changing it reopens Nib with the new file; the old one stays where it is, with its History.")
            }
            Section("Saving") {
                note("Nib saves a second after you stop typing, and whenever you switch away. There is no unsaved state to lose: everything you type is in its journal first.")
            }
            Section("This Mac") {
                LabeledContent("Name", value: ReceiptBook.shared.device)
                note("Your other Macs show this Mac by this name (“✓ SYNCED · ON \(ReceiptBook.shared.device.uppercased())”). Change it in System Settings › General › Sharing.")
            }
            Section("Notifications") {
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.banastas.nib") { NSWorkspace.shared.open(url) }
                }
                note("Only for a conflict, a file Nib can't save or sync, or one deleted or moved to the Trash, and only while Nib isn't in front. Saves and syncs never notify.")
            }
            Section("History") {
                note("Nib keeps each file's versions for 30 days, on this Mac only, as it does its journal. The files themselves are in iCloud Drive, which is end-to-end encrypted only with Advanced Data Protection.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: refusal) { _, why in if let why { Announce.sentence(why) } }   // said, not only shown (F62)
    }

    private func change() {
        refusal = nil
        guard let url = ScratchChoice.ask(), !ScratchChoice.isCurrent(url) else { return }
        if let why = ScratchChoice.refusal(url) { refusal = why; return }
        let alert = NSAlert()
        alert.messageText = "Use “\(url.lastPathComponent)” as the scratch file?"
        alert.informativeText = "It's in \(ScratchLocation.place(of: url)). Nib quits and opens again with it; “\(Documents.scratch.url.lastPathComponent)” stays where it is, with its History."
        alert.addButton(withTitle: "Reopen Nib")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { ScratchChoice.use(url) }
    }
}

/// Settings › Files: reopening the files open at a quit, and the kinds of file a double-click in
/// Finder opens in Nib (open question 15).
private struct FileSettings: View {
    private let apps = DefaultApps.shared
    @AppStorage(OpenTabs.settingKey, store: NibDefaults.store) private var reopenFiles = true

    var body: some View {
        Form {
            Section {
                // The files open at a quit, open again (the user's call, 2026-10-07; `OpenTabs`).
                Toggle("Reopen the files that were open when Nib quit", isOn: $reopenFiles)
                note("In their tabs, in the same order, the one in front in front again. Untitled buffers come back either way, and a file deleted since isn't made again.")
            }
            Section("Open with Nib") {
                ForEach(DefaultApps.Kind.allCases) { kind in
                    Toggle(isOn: Binding(get: { apps.openers[kind]?.isNib == true }, set: { on in Task { await apps.set(kind, on) } })) {
                        Text(kind.name)
                        Text(apps.openers[kind].map { $0.isNib ? kind.extensions : "\(kind.extensions) · now \($0.name)" } ?? kind.extensions)
                    }
                    .disabled(apps.changing.contains(kind))
                }
                if let failure = apps.failure {
                    Label { Text(failure).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.failure)
                    }
                }
                note("A double-click in Finder opens these files in Nib, and so does the open command in Terminal. Turning one off gives its files back to the app they opened in before. Shell scripts are files macOS can run, so it asks you to confirm each of .sh, .zsh and .bash: three times. For one file alone, use Finder's Get Info › Open With.")
                note("HTML isn't here: macOS opens every page on this Mac, a link in Terminal or a build's report, with the app for .html files, so they'd open in Nib as text. Nib still edits them: Open With, ⌘O, or nib page.html.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { apps.refresh() }
        .onChange(of: apps.failure) { _, why in if let why { Announce.sentence(why) } }   // F62
    }
}

/// A caption under a control (W7).
private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

struct EditorSettings: View {
    @AppStorage("editorTabSize", store: NibDefaults.store) private var tabSize = 4
    @AppStorage("editorSpaces", store: NibDefaults.store) private var spaces = false
    @AppStorage("editorLineNumbers", store: NibDefaults.store) private var lineNumbers = true
    @AppStorage("editorInvisibles", store: NibDefaults.store) private var invisibles = false
    @AppStorage("editorMinimap", store: NibDefaults.store) private var minimap = true
    @AppStorage("editorIndentGuides", store: NibDefaults.store) private var indentGuides = true
    @AppStorage("editorMatchBrackets", store: NibDefaults.store) private var matchBrackets = true
    @AppStorage("editorAutoPairs", store: NibDefaults.store) private var autoPairs = true
    @AppStorage("saveTrimsTrailingWhitespace", store: NibDefaults.store) private var trimOnSave = false
    @AppStorage("saveEnsuresFinalNewline", store: NibDefaults.store) private var newlineOnSave = false
    private static let families: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let first = manager.availableMembers(ofFontFamily: family)?.first, let name = first.first as? String else { return false }
            return NSFont(name: name, size: 13)?.isFixedPitch == true
        }
    }()

    var body: some View {
        let schemes = Schemes.shared
        Form {
            Section {
                Picker("Font", selection: Binding(get: { schemes.fontFace }, set: { schemes.setFont(face: $0, size: schemes.fontSize) })) {
                    Text("SF Mono").tag("")
                    Divider()
                    ForEach(Self.families.filter { $0 != "SF Mono" }, id: \.self) { Text($0).tag($0) }
                    if !schemes.fontFace.isEmpty, !Self.families.contains(schemes.fontFace) { Text(schemes.fontFace).tag(schemes.fontFace) }
                }
                Stepper(value: Binding(get: { schemes.fontSize }, set: { schemes.setFont(face: schemes.fontFace, size: $0) }), in: 8...36, step: 1) {
                    LabeledContent("Size", value: "\(schemes.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt")
                }
                note("The text's font in every window; bold and italic use its own faces. Text always wraps at the window's edge. Import from Sublime Text, in Themes, sets everything on this tab to what Sublime has.")
            }
            Section {
                Stepper(value: $tabSize, in: 1...16) { LabeledContent("Tab width", value: "\(tabSize)") }
                Toggle("Indent with spaces", isOn: $spaces)
                note("For files that don't show their own: a file indented with tabs or spaces keeps them, and the strip says which.")
            }
            Section {
                Toggle("Show line numbers", isOn: $lineNumbers)
                Toggle("Show invisibles", isOn: $invisibles)
                Toggle("Show minimap", isOn: $minimap)
                Toggle("Show indent guides", isOn: $indentGuides)
                Toggle("Underline matching brackets and tags", isOn: $matchBrackets)
                Toggle("Close brackets and quotes as you type", isOn: $autoPairs)
                note("Invisibles are spaces as dots and tabs as arrows; the minimap, the text at a seventh of its size to click or drag in. These three are in the View menu too. Closing pairs types the ) after a (, and over it when you type one.")
            }
            Section {
                Toggle("⌘S trims trailing whitespace", isOn: $trimOnSave)
                Toggle("⌘S ends the file with a newline", isOn: $newlineOnSave)
                note("Only on ⌘S, and only in files you've edited: Nib's own saves never change the text. ⌘Z undoes it.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

struct ThemeSettings: View {
    @State private var dropping = false

    var body: some View {
        let schemes = Schemes.shared
        Form {
            Section {
                Picker("Color scheme", selection: Binding(get: { schemes.currentID }, set: { schemes.use($0) })) {
                    ForEach(schemes.entries) { entry in
                        Text(entry.id == Schemes.builtIn ? "\(entry.name) (built in)" : entry.name).tag(entry.id)
                    }
                }
                if schemes.currentID != Schemes.builtIn {
                    Button("Move “\(schemes.current.name)” to the Trash") { schemes.remove(schemes.currentID) }
                        .help("Nib's copy goes to the Trash, where you can put it back; the file you imported it from isn't touched")
                }
                note("Colors the page: the text, its background, the caret, the selection and the line numbers. Nib's windows, menus and status strip stay dark whatever the scheme.")
            }
            Section {
                HStack {
                    Button("Import from Sublime Text") { schemes.importFromSublime() }
                    Button("Import File…") { chooseFile() }
                }
                note("Import from Sublime Text takes Sublime's color scheme (with its override in Packages/User), its font and size, and its editor settings: tab width and spaces, line numbers, invisibles, indent guides, matching brackets, closing pairs and ⌘S tidying, and sets Nib's to match. Sublime's files are only read, never changed. You can also drop a .tmTheme or .sublime-color-scheme file here.")
            }
            if let report = schemes.report {
                Section("Last import") {
                    Text(report)
                        .font(HUDFont.terminal(15))
                        .foregroundStyle(HUDColor.bright)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HUDColor.background)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(HUDColor.border, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Last import: \(Spoken.sentence(report))")   // F61
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onChange(of: schemes.report) { _, report in if let report { Announce.hud(report) } }   // the import's report, said (F62)
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(4) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in Schemes.shared.importFile(url) }
            }
            return true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import a Color Scheme"
        panel.prompt = "Import"
        panel.allowedContentTypes = ["tmTheme", "sublime-color-scheme", "hidden-tmTheme", "hidden-color-scheme"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { Schemes.shared.importFile(url) }
    }
}
