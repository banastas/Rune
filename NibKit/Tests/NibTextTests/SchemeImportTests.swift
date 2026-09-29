// Theme import (PRD HL2-HL4): Sublime's lenient JSON, `.sublime-color-scheme` colors and
// adjusters, overrides, the import report, zip packages, and Import from Sublime against a
// generated Sublime folder (and Sublime's own schemes, when Sublime is installed).

import Foundation
import Testing

@testable import NibText

@Suite struct LenientJSONTests {
    @Test func commentsAndTrailingCommas() throws {
        let text = """
        {
            // a comment, with a comma,
            "url": "http://example.com/a//b", /* block, ] */
            "list": [1, 2, 3,],
            "quote": "a \\" // still text",
            "nested": { "a": "b", },
        }
        """
        let object = try LenientJSON.object(from: Data(text.utf8))
        #expect(object["url"] as? String == "http://example.com/a//b")
        #expect((object["list"] as? [Int]) == [1, 2, 3])
        #expect(object["quote"] as? String == "a \" // still text")
        #expect((object["nested"] as? [String: String]) == ["a": "b"])
    }

    @Test func notJSON() {
        #expect(throws: LenientJSON.Failure.self) { try LenientJSON.object(from: Data("{ nope".utf8)) }
    }
}

@Suite struct SchemeColorTests {
    func hex(_ text: String, _ variables: [String: String] = [:]) -> String? {
        var colors = SchemeColors(variables: variables)
        return colors.color(text)?.hex
    }

    @Test func forms() {
        #expect(hex("#fff") == "#FFFFFF")
        #expect(hex("#f008") == "#FF000088")
        #expect(hex("#1C1D21") == "#1C1D21")
        #expect(hex("#00000080") == "#00000080")
        #expect(hex("rgb(255, 0, 0)") == "#FF0000")
        #expect(hex("rgba(0, 0, 0, 0.5)") == "#00000080")
        #expect(hex("rgb(100% 0% 0% / 50%)") == "#FF000080")
        #expect(hex("hsl(0, 100%, 50%)") == "#FF0000")
        #expect(hex("hsl(210, 50%, 60%)") == "#6699CC")
        #expect(hex("hsla(120, 100%, 25%, 1)") == "#008000")
        #expect(hex("hwb(0, 0%, 0%)") == "#FF0000")
        #expect(hex("rebeccapurple") == "#663399")
        #expect(hex("transparent") == "#00000000")
        #expect(hex("underline") == nil)
        #expect(hex("#12") == nil)
    }

    @Test func variables() {
        let vars = ["base": "hsl(0, 0%, 50%)", "text": "var(base)", "loop": "var(loop)"]
        #expect(hex("var(text)", vars) == "#808080")
        #expect(hex("var(missing)", vars) == nil)
        #expect(hex("var(loop)", vars) == nil)   // no endless recursion
    }

    @Test func adjusters() {
        let vars = ["white": "#FFFFFF", "black": "#000000", "grey": "hsl(0, 0%, 50%)"]
        #expect(hex("color(var(white) alpha(0.5))", vars) == "#FFFFFF80")
        #expect(hex("color(var(white) a(50%))", vars) == "#FFFFFF80")
        #expect(hex("color(#FFFFFF80 a(+ 0.25))", vars) == "#FFFFFFC0")
        #expect(hex("color(#FFFFFF80 a(- 25%))", vars) == "#FFFFFF40")
        #expect(hex("color(#FFFFFF80 alpha(* 0.5))", vars) == "#FFFFFF40")
        #expect(hex("color(var(grey) l(- 20%))", vars) == "#4D4D4D")
        #expect(hex("color(var(grey) lightness(75%))", vars) == "#BFBFBF")
        #expect(hex("color(hsl(0, 100%, 50%) s(50%))", vars) == "#BF4040")
        #expect(hex("color(hsl(0, 100%, 50%) s(* 0.5))", vars) == "#BF4040")
        #expect(hex("color(var(black) blend(var(white) 50%))", vars) == "#808080")
        #expect(hex("color(var(black) blend(var(white) 75%))", vars) == "#404040")          // keeps 75% of the base
        #expect(hex("color(#00000000 blenda(#FFFFFF 50%))", vars) == "#80808080")
        #expect(hex("color(#FF0000 blend(#0000FF 50% hsl))", vars) == "#FF00FF")            // halfway round the hue
        let low = hex("color(#444444 min-contrast(#1C1D21 4.5))", vars).flatMap(RGBA.init(hex:))
        #expect(low != nil && low!.contrast(RGBA(hex: "#1C1D21")!) >= 4.5)
        #expect(hex("color(var(white) alpha(0.5) l(- 50%))", vars) == "#80808080")         // adjusters in order
    }

    @Test func contrastMatchesThePRD() {
        // HL10's table: the original An Old Hope's colors on #1C1D21.
        let page = RGBA(hex: "#1C1D21")!
        func ratio(_ hex: String) -> String { String(format: "%.1f", RGBA(hex: hex)!.contrast(page)) }
        #expect(ratio("#7851A9") == "2.8")   // 2.85: the PRD had rounded twice (2.9)
        #expect(ratio("#767676") == "3.7")
        #expect(ratio("#EB3D54") == "4.3")
        #expect(String(format: "%.1f", RGBA(hex: "#F8F8F0")!.contrast(RGBA(hex: "#F92672")!)) == "3.5")   // 3.55
        #expect(String(format: "%.0f", RGBA(hex: "#FFFFFF")!.contrast(RGBA(hex: "#000000")!)) == "21")
    }
}

@Suite struct SublimeColorSchemeTests {
    static let sample = """
    {
        // A generated scheme with every construct Nib reads.
        "name": "Sample",
        "variables": {
            "bg": "hsl(220, 10%, 12%)",
            "fg": "#E0E0E0",
            "blue": "hsla(210, 50%, 60%, 1)",
            "red": "rgb(236, 71, 93)",
        },
        "globals": {
            "background": "var(bg)",
            "foreground": "var(fg)",
            "caret": "color(var(fg) alpha(0.8))",
            "line_highlight": "color(var(bg) l(+ 5%))",
            "selection": "var(blue)",
            "brackets_options": "underline",
            "shadow_width": 8,
            "gutter": "nope(1)",
        },
        "rules": [
            { "name": "Comment", "scope": "comment", "foreground": "color(var(fg) alpha(0.5))", "font_style": "italic" },
            { "name": "String", "scope": "string - string.regexp", "foreground": "var(blue)" },
            { "name": "Keyword", "scope": "keyword, storage", "foreground": "var(red)", "font_style": "bold stippled_underline glow" },
            { "name": "Rainbow", "scope": "meta.rainbow", "foreground": ["var(red)", "var(blue)"] },
            { "name": "Deleted", "scope": "markup.deleted", "background": "#420E09", "foreground_adjust": "l(- 20%)" },
        ],
    }
    """

    @Test func readsVariablesGlobalsAndRules() throws {
        let theme = try Theme(sublimeColorScheme: Data(Self.sample.utf8))
        #expect(theme.name == "Sample")
        #expect(theme.background.hex == "#1C1E22")
        #expect(theme.globals["line_highlight"] == "#272A30")
        #expect(theme.globals["caret"] == "#E0E0E0CC")
        #expect(theme.globals["brackets_options"] == "underline" && theme.globals["shadow_width"] == "8")
        #expect(theme.rules.count == 5)
        #expect(theme.style(for: "source.js comment.line").italic)
        #expect(theme.style(for: "source.js string.quoted").foreground.hex == "#6699CC")
        #expect(theme.style(for: "source.js string.regexp").foreground.hex == "#E0E0E0")   // excluded
        let keyword = theme.style(for: "source.js keyword.control")
        #expect(keyword.foreground.hex == "#EC475D" && keyword.bold && keyword.underline)
        #expect(theme.style(for: "source.js meta.rainbow").foreground.hex == "#EC475D")
        // foreground_adjust: the text under the deleted background, 20 points darker.
        let deleted = theme.style(for: "source.diff markup.deleted")
        #expect(deleted.background?.hex == "#420E09" && deleted.foreground.hex == "#ADADAD")
        #expect(theme.approximations == ["GLOW LEFT OUT", "GRADIENT TEXT AS ITS FIRST COLOR", "STIPPLED AND SQUIGGLY UNDERLINES AS UNDERLINE"])
        #expect(theme.unread == ["gutter “nope(1)”"])
    }

    @Test func overrides() throws {
        // Sublime's override: its variables replace the base's (so the base's rules change),
        // its rules come after (so they win ties).
        let base = try Theme.document(sublimeColorScheme: Data(Self.sample.utf8))
        let override = try LenientJSON.object(from: Data("""
        { "variables": { "blue": "#00FF00" }, "globals": { "caret": "#FF0000" },
          "rules": [ { "scope": "comment", "foreground": "#FFFFFF" } ] }
        """.utf8))
        let theme = try Theme(document: Theme.merging(base, override), fallbackName: "x")
        #expect(theme.name == "Sample")
        #expect(theme.style(for: "string").foreground.hex == "#00FF00")
        #expect(theme.globals["caret"] == "#FF0000")
        #expect(theme.style(for: "comment").foreground.hex == "#FFFFFF" && theme.style(for: "comment").italic)
        #expect(theme.rules.count == 6)
    }

    @Test func aTmThemeInTheSameShape() throws {
        // A .tmTheme's globals take .sublime-color-scheme's names; stored and read back, it's the same scheme.
        let theme = ThemeTests.theme
        #expect(theme.globals["line_highlight"] == "#272B34" && theme.globals["inactive_selection"] == "#3A3A3A")
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("themes/an-old-hope-nib.tmTheme")
        let document = try Theme.document(file: Data(contentsOf: url), named: url.lastPathComponent)
        let again = try Theme(sublimeColorScheme: Theme.storable(document))
        #expect(again.name == theme.name && again.rules.count == theme.rules.count && again.globals == theme.globals)
        for scope in ["source.js keyword.control", "source.js variable.parameter", "text.html.markdown markup.heading.1", "source.js invalid.illegal"] {
            #expect(again.style(for: scope) == theme.style(for: scope))
        }
    }

    @Test func notAScheme() {
        #expect(throws: (any Error).self) { try Theme(sublimeColorScheme: Data("{ \"a\": 1 }".utf8)) }
        #expect(throws: (any Error).self) { try Theme(tmTheme: Data("not a plist".utf8)) }
    }
}

@Suite struct ThemeReportTests {
    /// The original An Old Hope's globals and a few of its rules (HL10's table), generated.
    static let original: Theme = {
        let globals = ["bracketsOptions": "underline", "findHighlightForeground": "#000000", "foreground": "#F8F8F2",
                       "background": "#1C1D21", "caret": "#F8F8F0", "shadowWidth": "8", "shadow": "#00000080",
                       "selection": "#49483E", "tagsOptions": "stippled_underline", "activeGuide": "#4A4A4A",
                       "bracketsForeground": "#F8F8F0", "findHighlight": "#FFE792", "guide": "#2D2D2D",
                       "invisibles": "#3B3A32", "inactiveSelection": "#3A3A3A", "bracketContentsOptions": "underline",
                       "bracketContentsForeground": "#F8F8F0", "stackGuide": "#3A3A3A", "lineHighlight": "#2F3542",
                       "selectionBorder": "#666666"]
        let rules: [[String: Any]] = [
            ["name": "Comment", "scope": "comment", "settings": ["foreground": "#767676"]],
            ["name": "String", "scope": "string", "settings": ["foreground": "#50B4D8"]],
            ["name": "Number", "scope": "constant.numeric", "settings": ["foreground": "#7851A9"]],
            ["name": "Built-in constant", "scope": "constant.language", "settings": ["foreground": "#7851A9"]],
            ["name": "Keyword", "scope": "keyword", "settings": ["foreground": "#EB3D54"]],
            ["name": "Invalid", "scope": "invalid", "settings": ["foreground": "#F8F8F0", "background": "#F92672"]],
        ]
        let plist: [String: Any] = ["name": "an-old-hope", "settings": [["settings": globals]] + rules]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try! Theme(tmTheme: data)
    }()

    @Test func theOriginalAnOldHope() {
        let facts = ThemeReport.facts(for: Self.original)
        #expect(facts == [
            "IMPORTED AN-OLD-HOPE", "6 RULES", "9 GLOBALS USED",
            "11 NOT DRAWN YET (BRACKETS, TAGS, GUIDES, SELECTION BORDER, SHADOW)",
            "4 COLORS UNDER 4.5:1: #767676 COMMENT 3.7, #7851A9 NUMBER 2.8, #EB3D54 KEYWORD 4.3, #F8F8F0 ON #F92672 INVALID 3.5",
        ], "\(facts)")
        #expect(Self.original.isOriginalAnOldHope && !ThemeTests.theme.isOriginalAnOldHope)
    }

    /// PRD §9: the built-in scheme keeps every text color at 4.5:1 or more.
    @Test func theNibEditionPassesContrast() {
        let low = ThemeReport.lowContrast(ThemeTests.theme)
        #expect(low.isEmpty, "\(low.map { "\($0.color.hex) \($0.name) \(String(format: "%.2f", $0.ratio))" })")
        #expect(ThemeReport.facts(for: ThemeTests.theme).contains("EVERY COLOR AT LEAST 4.5:1 ON THE BACKGROUND"))
    }

    @Test func aLightScheme() throws {
        let theme = try Theme(sublimeColorScheme: Data("""
        { "name": "Paper", "globals": { "background": "#FAFAFA", "foreground": "#222222" }, "rules": [] }
        """.utf8))
        let facts = ThemeReport.facts(for: theme)
        #expect(facts.contains("LIGHT BACKGROUND · NIB'S WINDOWS STAY DARK") && facts.contains("0 RULES") && facts.contains("2 GLOBALS USED"))
        #expect(!facts.contains { $0.contains("NOT DRAWN") })
    }
}

/// A scratch folder for one test, removed afterwards.
final class Scratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nib-tests-\(UUID().uuidString)")
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ text: String) {
        let file = url.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    /// Zips a folder's contents with /usr/bin/zip (deflated, or stored with `-0`).
    func zip(_ folder: String, to archive: String, stored: Bool = false) throws {
        let out = url.appendingPathComponent(archive)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = url.appendingPathComponent(folder)
        process.arguments = ["-q", "-r", stored ? "-0" : "-9", out.path, "."]
        try process.run()
        process.waitUntilExit()
    }
}

@Suite struct ZipTests {
    @Test func storedAndDeflated() throws {
        let scratch = Scratch()
        let long = String(repeating: "a scheme's worth of text, compressible. ", count: 200)
        scratch.write("src/Mariana.sublime-color-scheme", long)
        scratch.write("src/nested/Other.txt", "short")
        scratch.write("src/empty.txt", "")
        for stored in [false, true] {
            let name = stored ? "stored.zip" : "deflated.zip"
            try scratch.zip("src", to: name, stored: stored)
            let zip = try #require(ZipArchive(url: scratch.url.appendingPathComponent(name)))
            #expect(zip.contents(of: "Mariana.sublime-color-scheme").map { String(decoding: $0, as: UTF8.self) } == long)
            #expect(zip.contents(of: "nested/Other.txt").map { String(decoding: $0, as: UTF8.self) } == "short")
            #expect(zip.contents(of: "empty.txt") == Data())
            #expect(zip.contents(of: "missing") == nil)
        }
        #expect(ZipArchive(data: Data("not a zip at all, but long enough to look".utf8)) == nil)
    }
}

@Suite struct SublimeImportTests {
    /// A generated Sublime: the app's Default package (settings), a scheme in an installed
    /// package, the user's settings and an override in Packages/User.
    func sublime(user: String) throws -> (Scratch, SublimeImport) {
        let s = Scratch()
        s.write("app-default/Preferences.sublime-settings", """
        { "color_scheme": "Mariana.sublime-color-scheme", "font_face": "", "font_size": 10, "tab_size": 4,
          "translate_tabs_to_spaces": false, "word_wrap": "auto", "line_padding_top": 0, }
        """)
        s.write("app-default/Preferences (OSX).sublime-settings", """
        { "font_face": "Menlo", "font_size": 12, } // the Mac's defaults
        """)
        try s.zip("app-default", to: "app/Packages/Default.sublime-package")
        s.write("mariana/Mariana.sublime-color-scheme", """
        { "name": "Mariana", "variables": { "blue": "hsl(210, 15%, 22%)" },
          "globals": { "background": "var(blue)", "foreground": "#FFFFFF" },
          "rules": [ { "name": "Comment", "scope": "comment", "foreground": "#A6ACB9" } ] }
        """)
        try s.zip("mariana", to: "app/Packages/Color Scheme - Default.sublime-package")
        s.write("data/Installed Packages/.keep", "")
        s.write("data/Packages/User/Preferences.sublime-settings", user)
        return (s, SublimeImport(data: s.url.appendingPathComponent("data"), appPackages: s.url.appendingPathComponent("app/Packages")))
    }

    @Test func aSchemeFromTheAppsPackagesByName() throws {
        let (s, sublime) = try sublime(user: "{ \"font_size\": 14 }")
        let found = try sublime.run()
        #expect(found.scheme.name == "Mariana" && found.source == "Packages/Color Scheme - Default/Mariana.sublime-color-scheme")
        #expect(found.scheme.background.hex == "#303841")
        #expect(found.fontFace == "Menlo" && found.fontSize == 14 && found.tabSize == 4)
        #expect(found.translateTabsToSpaces == false && found.wordWrap == "auto" && found.linePaddingTop == 0)
        #expect(try Theme(sublimeColorScheme: found.document).background.hex == "#303841")
        _ = s
    }

    @Test func aLooseTmThemeWithAnOverride() throws {
        let (s, sublime) = try sublime(user: """
        { "color_scheme": "Packages/User/an-old-hope.tmTheme", "font_face": "SF Mono", "translate_tabs_to_spaces": true }
        """)
        let plist: [String: Any] = ["name": "an-old-hope", "settings": [
            ["settings": ["background": "#1C1D21", "foreground": "#F8F8F2", "lineHighlight": "#2F3542"]],
            ["name": "Number", "scope": "constant.numeric", "settings": ["foreground": "#7851A9"]],
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: s.url.appendingPathComponent("data/Packages/User/an-old-hope.tmTheme"))
        s.write("data/Packages/User/an-old-hope.sublime-color-scheme", """
        { "rules": [ { "scope": "constant.numeric", "foreground": "#EF7C2B" } ] } // a user's override
        """)
        let found = try sublime.run()
        #expect(found.source == "Packages/User/an-old-hope.tmTheme" && found.override == "Packages/User/an-old-hope.sublime-color-scheme")
        #expect(found.scheme.isOriginalAnOldHope)
        #expect(found.scheme.style(for: "source.js constant.numeric").foreground.hex == "#EF7C2B")
        #expect(found.scheme.globals["line_highlight"] == "#2F3542")
        #expect(found.fontFace == "SF Mono" && found.fontSize == 12 && found.translateTabsToSpaces == true)
    }

    @Test func autoUsesTheDarkScheme() throws {
        let (s, sublime) = try sublime(user: """
        { "color_scheme": "auto", "dark_color_scheme": "Packages/Color Scheme - Default/Mariana.sublime-color-scheme", "light_color_scheme": "Nope.sublime-color-scheme" }
        """)
        #expect(try sublime.run().scheme.name == "Mariana")
        _ = s
    }

    @Test func failures() throws {
        let (s, sublime) = try sublime(user: "{ \"color_scheme\": \"Missing.sublime-color-scheme\" }")
        #expect(throws: SublimeImport.Failure.self) { try sublime.run() }
        #expect(throws: SublimeImport.Failure.self) { try SublimeImport(data: s.url.appendingPathComponent("nowhere"), appPackages: nil).run() }
    }

    /// Sublime's own schemes, when it's installed: every color read.
    @Test func sublimesBuiltInSchemes() throws {
        let packages = URL(fileURLWithPath: "/Applications/Sublime Text.app/Contents/MacOS/Packages")
        guard let zip = ZipArchive(url: packages.appendingPathComponent("Color Scheme - Default.sublime-package")) else { return }
        #expect(zip.entries.count >= 5)
        for name in zip.entries.keys where name.hasSuffix(".sublime-color-scheme") {
            let theme = try Theme(sublimeColorScheme: #require(zip.contents(of: name)), fallbackName: name)
            #expect(theme.unread.isEmpty, "\(name): \(theme.unread)")
            #expect(theme.rules.count > 10 && theme.globals["background"] != nil, "\(name)")
        }
    }
}

@Suite struct GutterTests {
    @Test func lineNumbersStayReadable() throws {
        let plain = try Theme(sublimeColorScheme: Data(##"{"globals": {"foreground": "#FFFFFF", "background": "#000000"}}"##.utf8))
        let dimmed = plain.gutterForeground
        #expect(dimmed.contrast(plain.gutter) >= 4.5 && dimmed.contrast(plain.gutter) < 21 && plain.gutter == plain.background)
        let set = try Theme(sublimeColorScheme: Data(##"{"globals": {"foreground": "#FFFFFF", "background": "#000000", "gutter": "#101010", "gutter_foreground": "#505050"}}"##.utf8))
        #expect(set.gutterForeground.hex == "#505050" && set.gutter.hex == "#101010")   // the scheme's own, as set
    }
}

