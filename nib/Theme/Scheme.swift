// The editor's look (PRD HL2-HL6, A1): the color scheme in use and the editor font. An Old
// Hope · Nib is built in (HL10); imported schemes are kept in
// ~/Library/Application Support/nib/Themes/ as `.sublime-color-scheme` files, variables and
// overrides included. Settings › Themes picks one, Import File… and Import from Sublime Text
// add them (HL3), and each import leaves a report (HL4). The scheme colors the text area
// only; Nib's windows stay dark (A17). Views read `Scheme`; editors redraw when it changes.

import AppKit
import NibSyntax
import NibSync
import NibText

extension Notification.Name {
    /// The scheme or the editor font changed.
    static let nibSchemeChanged = Notification.Name("NibSchemeChanged")
}

/// The scheme in use, as the views draw it: the scheme's globals (HL5), falling back to An
/// Old Hope · Nib's where a scheme doesn't set one, and Nib's own conflict colors (V3).
@MainActor
enum Scheme {
    static var theme: Theme { Schemes.shared.current }
    static var font: NSFont { Schemes.shared.font }

    static var background: NSColor { NSColor(theme.background) }
    static var foreground: NSColor { NSColor(theme.foreground) }
    static var caret: NSColor { global("caret") ?? foreground }
    static var selection: NSColor { global("selection") ?? color(0x49483E) }
    static var inactiveSelection: NSColor { global("inactive_selection") ?? selection }
    static var lineHighlight: NSColor { global("line_highlight") ?? background.blended(withFraction: 0.06, of: .white) ?? background }
    /// Conflict blocks (§5.4): a dark tint of the one red behind the block, and its marker
    /// lines in the red's text tint (V3, #C98080), so they read as Nib's, not the text's.
    static var conflictBlock: NSColor {
        theme.background.hex == "#1C1D21" ? color(0x2B2124) : background.blended(withFraction: 0.1, of: conflictBar) ?? background
    }
    static let conflictMarker = color(0xC98080)
    static let conflictBar = color(0xB35C5C)
    /// The scheme's own diff backgrounds (`markup.inserted`, `.changed`), for the merge view (§5.5).
    static var markupInserted: NSColor { theme.style(for: "markup.inserted").background.map(NSColor.init) ?? color(0x253B22) }
    static var markupDeleted: NSColor { theme.style(for: "markup.deleted").background.map(NSColor.init) ?? color(0x420E09) }
    static var markupChanged: NSColor { theme.style(for: "markup.changed").background.map(NSColor.init) ?? color(0x4A4A0F) }
    static var comment: NSColor { NSColor(theme.style(for: "comment").foreground) }
    /// Line numbers (ED6): the gutter, its numbers (at least 4.5:1, unless the scheme sets its
    /// own), and the caret's line's number in the text color.
    static var gutter: NSColor { NSColor(theme.gutter) }
    static var gutterForeground: NSColor { NSColor(theme.gutterForeground) }
    static var gutterForegroundHighlight: NSColor { global("gutter_foreground_highlight") ?? foreground }
    /// ED10: indent guides in the scheme's `guide` (An Old Hope's #2D2D2D); the brackets beside
    /// the caret underlined in its `brackets_foreground` (#F8F8F0), the pair round it in its
    /// `bracket_contents_foreground`; an HTML element's tag names in `tags_foreground`, or their
    /// own color.
    static var guide: NSColor { global("guide") ?? foreground.withAlphaComponent(0.12) }
    static var bracketsForeground: NSColor { global("brackets_foreground") ?? foreground }
    static var bracketContentsForeground: NSColor { global("bracket_contents_foreground") ?? bracketsForeground }
    static var tagsForeground: NSColor { global("tags_foreground") ?? NSColor(theme.style(for: "entity.name.tag.html").foreground) }
    /// "underline", "stippled_underline", "squiggly_underline", "foreground", "bold" or "glow";
    /// Nib draws the underlines (a stippled one dotted), and an underline for the others.
    static func stippled(_ option: String, else fallback: Bool) -> Bool {
        guard let value = theme.globals[option] else { return fallback }
        return value.hasPrefix("stippled") || value.hasPrefix("squiggly")
    }

    /// Show Invisibles (ED6): the scheme's `invisibles` (An Old Hope's #3B3A32, faint on purpose).
    static var invisibles: NSColor { global("invisibles") ?? foreground.withAlphaComponent(0.3) }
    /// Find's other matches (ED7): the scheme's `find_highlight` behind them, and its
    /// `find_highlight_foreground` if it sets one (An Old Hope · Nib's: black on #FFE792).
    static var findHighlight: NSColor { global("find_highlight") ?? color(0xFFE792) }
    static var findHighlightForeground: NSColor? { global("find_highlight_foreground") ?? (global("find_highlight") == nil ? .black : nil) }

    private static func global(_ name: String) -> NSColor? { theme.color(name).map(NSColor.init) }

    static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

@MainActor
@Observable
final class Schemes {
    static let shared = Schemes()

    struct Entry: Identifiable, Hashable {
        /// "built-in", or the file's name in the Themes folder.
        let id: String
        let name: String
    }

    static let builtIn = "built-in"
    static var folder: URL { NibPaths.support.appendingPathComponent("Themes") }

    private(set) var entries: [Entry] = []
    private(set) var currentID = builtIn
    private(set) var current = Theme.anOldHopeNib
    private(set) var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// "" is SF Mono, the system's monospaced font.
    private(set) var fontFace = ""
    private(set) var fontSize = 13.0
    /// The last import's report (HL4), in the HUD's words.
    private(set) var report: String?

    private let defaults = NibDefaults.store

    private init() {
        #if DEBUG
        AppDelegate.mark("schemes loading")
        #endif
        report = defaults.string(forKey: "schemeReport")
        fontFace = defaults.string(forKey: "editorFontFace") ?? ""
        fontSize = defaults.object(forKey: "editorFontSize") as? Double ?? 13
        font = Self.font(face: fontFace, size: fontSize) ?? font
        reload()
        if let id = defaults.string(forKey: "scheme"), id != Self.builtIn, let theme = load(id) {
            currentID = id
            current = theme
        }
    }

    /// The built-in scheme and the imported ones, by name.
    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        let imported = files.filter { $0.pathExtension == "sublime-color-scheme" }.compactMap { url in
            load(url.lastPathComponent).map { Entry(id: url.lastPathComponent, name: $0.name) }
        }
        entries = [Entry(id: Self.builtIn, name: Theme.anOldHopeNib.name)] + imported.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func load(_ id: String) -> Theme? {
        if id == Self.builtIn { return .anOldHopeNib }
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(id)) else { return nil }
        return try? Theme(sublimeColorScheme: data, fallbackName: (id as NSString).deletingPathExtension)
    }

    func use(_ id: String) {
        guard let theme = load(id) else { return }
        currentID = id
        current = theme
        defaults.set(id, forKey: "scheme")
        NotificationCenter.default.post(name: .nibSchemeChanged, object: nil)
    }

    /// Takes an imported scheme out of the list, and the file out of the Themes folder.
    func remove(_ id: String) {
        guard id != Self.builtIn else { return }
        if currentID == id { use(Self.builtIn) }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(id))
        reload()
    }

    /// The editor font: a family or font name, "" for SF Mono.
    func setFont(face: String, size: Double) {
        guard let chosen = Self.font(face: face, size: size) else { return }
        fontFace = face
        fontSize = size
        font = chosen
        defaults.set(face, forKey: "editorFontFace")
        defaults.set(size, forKey: "editorFontSize")
        NotificationCenter.default.post(name: .nibSchemeChanged, object: nil)
    }

    static func font(face: String, size: Double) -> NSFont? {
        let size = CGFloat(min(72, max(6, size)))
        if face.isEmpty || face == "SF Mono" || face == "SFMono-Regular" { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFontManager.shared.font(withFamily: face, traits: [], weight: 5, size: size) ?? NSFont(name: face, size: size)
    }

    // MARK: Import (HL2-HL4)

    /// Sublime Text's settings and scheme as found, nothing changed yet.
    private func findSublime() throws -> SublimeImport.Found {
        let data = defaults.string(forKey: "NibSublimeFolder").map { URL(fileURLWithPath: $0) } ?? SublimeImport.dataFolder()
        let packages = defaults.string(forKey: "NibSublimePackages").map { URL(fileURLWithPath: $0) }
            ?? (NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.sublimetext.4")
                ?? URL(fileURLWithPath: "/Applications/Sublime Text.app")).appendingPathComponent("Contents/MacOS/Packages")
        guard let data else { throw SublimeImport.Failure.noSublime }
        return try SublimeImport(data: data, appPackages: packages).run()
    }

    /// What Import from Sublime Text would bring, for the first run's Look step (§5.9):
    /// "MENLO 13 · TAB SIZE 2 · SPACES · MONOKAI", or why there's nothing (HUD words, W1).
    func sublimePreview() -> (found: String?, failure: String?) {
        do {
            let found = try findSublime()
            var parts: [String] = []
            if let size = found.fontSize {
                let face = found.fontFace ?? ""
                parts.append("\(face.isEmpty ? "SF MONO" : face.uppercased()) \(size.formatted(.number.precision(.fractionLength(0...1))))")
            }
            if let tab = found.tabSize { parts.append("TAB SIZE \(tab)") }
            if let spaces = found.translateTabsToSpaces { parts.append(spaces ? "SPACES" : "TABS") }
            parts.append(found.scheme.isOriginalAnOldHope ? "\(found.scheme.name.uppercased()) (NIB KEEPS ITS OWN EDITION)" : found.scheme.name.uppercased())
            return (parts.joined(separator: " · "), nil)
        } catch let failure as SublimeImport.Failure {
            return (nil, failure.description)
        } catch {
            return (nil, "COULDN'T READ SUBLIME TEXT'S SETTINGS · \(error.localizedDescription.uppercased())")
        }
    }

    /// A `.tmTheme` or `.sublime-color-scheme` from anywhere: kept, used, and reported on.
    @discardableResult
    func importFile(_ url: URL) -> Bool {
        do {
            let document = try Theme.document(file: Data(contentsOf: url), named: url.lastPathComponent)
            let theme = try Theme(document: document, fallbackName: url.deletingPathExtension().lastPathComponent)
            try keep(document, named: theme.name)
            setReport(ThemeReport.facts(for: theme))
            return true
        } catch {
            setReport(["COULDN'T READ “\(url.lastPathComponent.uppercased())” · NOT A COLOR SCHEME NIB CAN READ · NOTHING IMPORTED"])
            return false
        }
    }

    /// Sublime Text's scheme, its override, and its font (HL3), read and never changed. The
    /// original An Old Hope is kept as the Nib edition (HL10). A test run points it elsewhere
    /// with -NibSublimeFolder and -NibSublimePackages.
    @discardableResult
    func importFromSublime() -> Bool {
        do {
            let found = try findSublime()
            var facts: [String]
            if found.scheme.isOriginalAnOldHope {
                use(Self.builtIn)
                facts = ["SUBLIME TEXT USES \(found.scheme.name.uppercased())",
                         "KEPT \(Theme.anOldHopeNib.name.uppercased()), ITS CORRECTED EDITION: EVERY COLOR AT LEAST 4.5:1"]
            } else {
                try keep(Theme.document(sublimeColorScheme: found.document), named: found.scheme.name)
                facts = ThemeReport.facts(for: found.scheme)
            }
            if let override = found.override { facts.insert("WITH \((override as NSString).lastPathComponent.uppercased())", at: 1) }
            if let size = found.fontSize {
                let face = found.fontFace ?? ""
                let label = "\(face.isEmpty ? "SF MONO" : face.uppercased()) \(size.formatted(.number.precision(.fractionLength(0...1))))"
                if Self.font(face: face, size: size) != nil {
                    setFont(face: face, size: size)
                    facts.append("FONT \(label)")
                } else {
                    facts.append("FONT \(label) NOT INSTALLED · KEPT \(fontLabel)")
                }
            }
            // Tab size and spaces or tabs: for files that don't show their own (ED6).
            if let tab = found.tabSize { defaults.set(tab, forKey: "editorTabSize") }
            if let spaces = found.translateTabsToSpaces { defaults.set(spaces, forKey: "editorSpaces") }
            if found.tabSize != nil || found.translateTabsToSpaces != nil {
                facts.append([found.tabSize.map { "TAB SIZE \($0)" }, found.translateTabsToSpaces.map { $0 ? "SPACES" : "TABS" }].compactMap { $0 }.joined(separator: " · "))
            }
            // Line numbers and invisibles (ED6), as Sublime shows them.
            if let numbers = found.lineNumbers { defaults.set(numbers, forKey: "editorLineNumbers") }
            if let invisibles = found.invisibles { defaults.set(invisibles, forKey: "editorInvisibles") }
            // Indent guides, matching brackets and tags, closing pairs (ED10), as Sublime has them.
            if let guides = found.indentGuides { defaults.set(guides, forKey: "editorIndentGuides") }
            if let matches = found.matchBrackets { defaults.set(matches, forKey: "editorMatchBrackets") }
            if let pairs = found.autoPairs { defaults.set(pairs, forKey: "editorAutoPairs") }
            // Tidying on ⌘S (ED6), as Sublime does on save.
            if let trim = found.trimOnSave { defaults.set(trim, forKey: "saveTrimsTrailingWhitespace") }
            if let newline = found.newlineOnSave { defaults.set(newline, forKey: "saveEnsuresFinalNewline") }
            if found.trimOnSave == true || found.newlineOnSave == true {
                facts.append("ON ⌘S: " + [found.trimOnSave == true ? "TRIM TRAILING WHITESPACE" : nil, found.newlineOnSave == true ? "END WITH A NEWLINE" : nil].compactMap { $0 }.joined(separator: " · "))
            }
            if found.lineNumbers != nil || found.invisibles != nil {
                facts.append([found.lineNumbers.map { "LINE NUMBERS \($0 ? "ON" : "OFF")" }, found.invisibles.map { "INVISIBLES \($0 ? "ON" : "OFF")" }].compactMap { $0 }.joined(separator: " · "))
            }
            // These three are set too, and the report said nothing of them (the QA review's F25).
            if found.indentGuides != nil || found.matchBrackets != nil || found.autoPairs != nil {
                facts.append([found.indentGuides.map { "INDENT GUIDES \($0 ? "ON" : "OFF")" }, found.matchBrackets.map { "MATCHING BRACKETS \($0 ? "ON" : "OFF")" },
                              found.autoPairs.map { "CLOSING PAIRS \($0 ? "ON" : "OFF")" }].compactMap { $0 }.joined(separator: " · "))
            }
            var unused: [String] = []
            if let wrap = found.wordWrap { unused.append("WORD WRAP \(wrap.uppercased())"); defaults.set(wrap, forKey: "editorWordWrap") }
            let padding = [found.linePaddingTop ?? 0, found.linePaddingBottom ?? 0]
            if padding != [0, 0] { unused.append("LINE PADDING \(padding.map { $0.formatted() }.joined(separator: "/"))") }
            if !unused.isEmpty { facts.append(unused.joined(separator: ", ") + ": NOTED, NOT USED YET") }
            setReport(facts)
            return true
        } catch let failure as SublimeImport.Failure {
            setReport([failure.description])
        } catch {
            setReport(["COULDN'T IMPORT FROM SUBLIME TEXT · \(error.localizedDescription.uppercased())"])
        }
        return false
    }

    var fontLabel: String {
        "\(fontFace.isEmpty ? "SF MONO" : fontFace.uppercased()) \(fontSize.formatted(.number.precision(.fractionLength(0...1))))"
    }

    /// Writes the scheme into the Themes folder (replacing one of the same name) and uses it.
    private func keep(_ document: [String: Any], named name: String) throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let id = (slug.isEmpty ? "scheme" : slug) + ".sublime-color-scheme"
        try Theme.storable(document).write(to: Self.folder.appendingPathComponent(id), options: .atomic)
        reload()
        use(id)
    }

    private func setReport(_ facts: [String]) {
        report = facts.joined(separator: " · ")
        defaults.set(report, forKey: "schemeReport")
    }
}
