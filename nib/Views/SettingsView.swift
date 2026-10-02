// Settings (PRD §5.8, V12, W7): tabs, grouped forms that size to fit, 480 pt wide, and a
// plain note under each control saying what it does and doesn't do. General (open at login,
// the global shortcuts, the menu bar extra, the scratch file), Editor (the font and size,
// indentation, line numbers, invisibles, ⌘S tidying, Paste Clean) and Themes (the scheme,
// Import from Sublime Text, Import File…, and the last import's report, HL2-HL4).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab", store: NibDefaults.store) private var tab = "editor"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
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

/// Settings › General: open at login (AP2), the global shortcuts (SC2, PT4, SC6), the menu
/// bar extra (AP3) and the scratch file (SC1).
private struct GeneralSettings: View {
    @AppStorage("showMenuBarExtra", store: NibDefaults.store) private var showMenuBarExtra = true
    @State private var refusal: String?

    var body: some View {
        Form {
            Section {
                LoginToggle()
            }
            Section("Global shortcuts") {
                ForEach(GlobalShortcuts.Action.allCases) { ShortcutRow(action: $0) }
                note("They work from any app, with no Accessibility access, so macOS doesn't ask for any. Click one and press the new keys: with ⌘, ⌃ or ⌥, or a function key. Delete clears it; Escape keeps it. Append Clipboard to Scratch adds what you copied to the end of the scratch file without bringing Nib forward.")
            }
            Section {
                Toggle("Show Nib in the menu bar", isOn: $showMenuBarExtra)
                note("The nib in the menu bar shows the scratch file's sync at a glance: still when all's well, its line marching while an upload takes more than a few seconds, a red ✕ beside it when something needs a look. Click it for the scratch file's state, Clean Clipboard, Append Clipboard to Scratch and recent files. The global shortcuts work either way.")
            }
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
                note("Changing it reopens Nib with the new file. The old one stays where it is, with its History.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func change() {
        refusal = nil
        guard let url = ScratchChoice.ask(), !ScratchChoice.isCurrent(url) else { return }
        if let why = ScratchChoice.refusal(url) { refusal = why; return }
        let alert = NSAlert()
        alert.messageText = "Use “\(url.lastPathComponent)” as the scratch file?"
        alert.informativeText = "Nib reopens to use it, in \(ScratchLocation.place(of: url)). \(Documents.scratch.url.lastPathComponent) stays where it is."
        alert.addButton(withTitle: "Reopen Nib")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { ScratchChoice.use(url) }
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
    @AppStorage("pasteStraightensQuotes", store: NibDefaults.store) private var straightenQuotes = false
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
                note("The font of the text in every window. Bold and italic use the font's own faces. Import from Sublime Text, in Themes, sets these to Sublime's.")
            }
            Section {
                Stepper(value: $tabSize, in: 1...16) { LabeledContent("Tab width", value: "\(tabSize)") }
                Toggle("Indent with spaces", isOn: $spaces)
                note("For files that don't show their own. A file indented with tabs, or with spaces, keeps its own; the strip says which. Import from Sublime Text sets these to Sublime's.")
            }
            Section {
                Toggle("Show line numbers", isOn: $lineNumbers)
                Toggle("Show invisibles", isOn: $invisibles)
                Toggle("Show minimap", isOn: $minimap)
                Toggle("Show indent guides", isOn: $indentGuides)
                Toggle("Underline matching brackets and tags", isOn: $matchBrackets)
                Toggle("Close brackets and quotes as you type", isOn: $autoPairs)
                note("Line numbers in a gutter down the left, the caret's line brighter. Invisibles are spaces as dots and tabs as arrows, in the color scheme's own faint color. Import from Sublime Text sets these two to Sublime's. The minimap is the text at a seventh of its size beside the scroller, the lines in view under a box: click or drag in it to scroll. All three are in the View menu too. Indent guides, matching brackets and tags, and closing pairs are as in Sublime, in the color scheme's own colors; Import from Sublime Text sets them to Sublime's.")
            }
            Section {
                Toggle("⌘S trims trailing whitespace", isOn: $trimOnSave)
                Toggle("⌘S ends the file with a newline", isOn: $newlineOnSave)
                note("Only when you press ⌘S, and only in files you've edited: Nib's own saves, a second after you stop typing, never change the text. It's one change, and ⌘Z undoes it. Import from Sublime Text sets these to Sublime's.")
            }
            Section {
                Toggle("Paste Clean straightens quotes and dashes", isOn: $straightenQuotes)
                note("Paste Clean (⌥⇧⌘V) and Clean Clipboard (⌃⌥⌘V) always remove invisible characters, make odd spaces plain and trim trailing spaces. With this on they also turn “curly” quotes, en and em dashes and … into plain ones. ⌘V pastes text as it is.")
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
                    Button("Remove “\(schemes.current.name)”") { schemes.remove(schemes.currentID) }
                }
                note("Colors the text only. Nib is always dark: windows, menus and the status strip stay dark whatever the scheme.")
            }
            Section {
                HStack {
                    Button("Import from Sublime Text") { schemes.importFromSublime() }
                    Button("Import File…") { chooseFile() }
                }
                note("Import from Sublime Text reads the color scheme Sublime uses, its override in Packages/User, and Sublime's font; Sublime's files are only read, never changed. You can also drop a .tmTheme or .sublime-color-scheme file here.")
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
                        .accessibilityLabel("Last import: \(report.lowercased())")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
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
