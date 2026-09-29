// Settings (PRD §5.8, V12, W7): tabs, grouped forms that size to fit, 480 pt wide, and a
// plain note under each control saying what it does and doesn't do. For now: Editor (the
// font and size) and Themes (the scheme, Import from Sublime Text, Import File…, and the
// last import's report, HL2-HL4).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "editor"

    var body: some View {
        TabView(selection: $tab) {
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

/// A caption under a control (W7).
private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

struct EditorSettings: View {
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
