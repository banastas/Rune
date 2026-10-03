// Highlighting (PRD HL1, HL7, HL8, HL10): languages found by name and first line, scopes as Sublime
// gives them, the built-in scheme kept identical to themes/, and the fidelity bar itself:
// at least 98% of non-whitespace characters colored as in Sublime's dump (fidelity/sublime/).

import Foundation
import Testing

@testable import NibSyntax
@testable import NibText

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@Suite struct HighlightingTests {
    let theme = Theme.anOldHopeNib

    func color(of word: String, in text: String, _ language: SyntaxLanguage, root: String? = nil) -> String {
        let at = (text as NSString).range(of: word).location
        let run = Highlighter.runs(text, language: language, root: root).first { NSLocationInRange(at, $0.range) }!
        return theme.style(for: run.scopes).foreground.hex
    }

    @Test func theBuiltInSchemeIsTheOneInThemes() throws {
        let copy = try Data(contentsOf: repository.appendingPathComponent("NibKit/Sources/NibSyntax/Themes/an-old-hope-nib.tmTheme"))
        let canonical = try Data(contentsOf: repository.appendingPathComponent("themes/an-old-hope-nib.tmTheme"))
        #expect(copy == canonical, "NibKit/Sources/NibSyntax/Themes/ has drifted from themes/: copy it again")
        #expect(theme.rules.count == 42)
    }

    @Test func detection() {
        #expect(SyntaxLanguage.detect(fileName: "page.HTML")?.language == .html)
        #expect(SyntaxLanguage.detect(fileName: "app.mjs")?.language == .javascript)
        #expect(SyntaxLanguage.detect(fileName: "notes.md")?.language == .markdown)
        #expect(SyntaxLanguage.detect(fileName: ".zshrc")?.root == "source.shell.zsh")
        #expect(SyntaxLanguage.detect(fileName: "deploy", firstLine: "#!/bin/bash")?.language == .shell)
        #expect(SyntaxLanguage.detect(fileName: "notes.txt") == nil)
        // XML (HL8), as Sublime's XML syntax finds it: by name, or by its declaration or a
        // DOCTYPE that isn't HTML's on the first line.
        for name in ["feed.xml", "logo.SVG", "episodes.rss", "outline.opml", "An Old Hope.tmTheme", "App.csproj"] {
            #expect(SyntaxLanguage.detect(fileName: name)?.language == .xml, "\(name)")
        }
        #expect(SyntaxLanguage.detect(fileName: "launchd.plist", firstLine: #"<?xml version="1.0" encoding="UTF-8"?>"#)?.root == "text.xml")
        #expect(SyntaxLanguage.detect(fileName: "launchd.plist") == nil)
        #expect(SyntaxLanguage.detect(fileName: "data", firstLine: "<?xml")?.language == .xml)
        #expect(SyntaxLanguage.detect(fileName: "Info", firstLine: #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "x.dtd">"#)?.language == .xml)
        #expect(SyntaxLanguage.detect(fileName: "index", firstLine: "<!doctype html>") == nil)
        #expect(SyntaxLanguage.detect(fileName: "index", firstLine: "<!DOCTYPE html") == nil)
        #expect(SyntaxLanguage.detect(fileName: "index", firstLine: "<!DOCTYPE html\r") == nil)
        #expect(SyntaxLanguage.detect(fileName: "notes.md", firstLine: "<?xml version=\"1.0\"?>")?.language == .markdown)   // the name first
        // HL8's list, by Sublime's names and first lines.
        let named: [(String, SyntaxLanguage)] = [
            ("App.jsx", .jsx), ("store.ts", .typescript), ("vite.config.mts", .typescript), ("Panel.tsx", .tsx),
            ("fix.diff", .diff), ("0001-feed.patch", .diff), ("COMMIT_EDITMSG", .gitCommit), ("MERGE_MSG", .gitCommit),
            (".gitignore", .gitIgnore), ("global.gitignore", .gitIgnore), (".gitattributes", .gitAttributes),
            (".gitconfig", .gitConfig), (".gitmodules", .gitConfig), ("Makefile", .makefile), ("GNUmakefile", .makefile),
            ("rules.mk", .makefile), ("compose.yaml", .yaml), ("ci.yml", .yaml), ("pyproject.toml", .toml), ("Cargo.lock", .toml),
            ("Pipfile", .toml), ("tool.py", .python), ("stubs.pyi", .python), ("SConstruct", .python), ("setup.cfg", .ini),
            ("settings.ini", .ini), (".editorconfig", .ini), ("Preferences.sublime-settings", .json), ("Untitled.ipynb", .json),
            ("main.go", .go), ("cache.rs", .rust), ("sync.rb", .ruby), ("Gemfile", .ruby), ("Rakefile", .ruby), ("app.gemspec", .ruby),
            (".irbrc", .ruby), ("FeedParser.java", .java), ("buffer.c", .c), ("buffer.h", .c), ("config.lua", .lua),
            ("index.php", .php), ("page.phtml", .php), ("report.sql", .sql), ("guide.rst", .rst),
            ("FeedStore.swift", .swift), ("Package.swift", .swift), ("Foundation.swiftinterface", .swift),
            ("episodes.csv", .csv), ("Export.CSV", .csv), ("feeds.tsv", .tsv), ("table.tab", .tsv), ("sync.log", .log),
            ("system.log.0", .log), ("app.log.12", .log), ("syslog", .log),
        ]
        for (name, language) in named {
            #expect(SyntaxLanguage.detect(fileName: name)?.language == language, "\(name)")
        }
        for name in [".env", ".env.local", "production.env"] {
            #expect(SyntaxLanguage.detect(fileName: name)?.root == "source.shell.bash", "\(name)")
        }
        #expect(SyntaxLanguage.detect(fileName: "fetch", firstLine: "#!/usr/bin/env python3")?.language == .python)
        #expect(SyntaxLanguage.detect(fileName: "run", firstLine: "#!/usr/bin/env -S uv run --script")?.language == .python)
        #expect(SyntaxLanguage.detect(fileName: "serve", firstLine: "#!/usr/bin/env node")?.language == .javascript)
        #expect(SyntaxLanguage.detect(fileName: "task", firstLine: "#!/usr/bin/env ts-node")?.language == .typescript)
        #expect(SyntaxLanguage.detect(fileName: "build", firstLine: "#!/usr/bin/make -f")?.language == .makefile)
        #expect(SyntaxLanguage.detect(fileName: "spec", firstLine: "%YAML 1.2")?.language == .yaml)
        #expect(SyntaxLanguage.detect(fileName: "config", firstLine: "[core]")?.language == .gitConfig)   // a repository's .git/config
        #expect(SyntaxLanguage.detect(fileName: "changes", firstLine: "--- a/src/feed.js")?.language == .diff)
        #expect(SyntaxLanguage.detect(fileName: "changes", firstLine: "Index: src/feed.js")?.language == .diff)
        #expect(SyntaxLanguage.detect(fileName: "notes.txt", firstLine: "# Notes") == nil)
        #expect(SyntaxLanguage.detect(fileName: "catalog.logs") == nil)
        #expect(SyntaxLanguage.detect(fileName: "blog.md")?.language == .markdown)
        #expect(SyntaxLanguage.detect(fileName: "deploy", firstLine: "#!/usr/bin/env ruby")?.language == .ruby)
        #expect(SyntaxLanguage.detect(fileName: "script", firstLine: "#!/usr/bin/env lua")?.language == .lua)
        #expect(SyntaxLanguage.detect(fileName: "page", firstLine: "<?php")?.language == .php)
        #expect(SyntaxLanguage.detect(fileName: "run", firstLine: "#!/usr/bin/env php")?.language == .php)
        #expect(SyntaxLanguage.detect(fileName: "release", firstLine: "#!/usr/bin/env swift")?.language == .swift)
        #expect(SyntaxLanguage.detect(fileName: "release", firstLine: "#!/usr/bin/xcrun swift -O")?.language == .swift)
    }

    /// Nib's own colors where Sublime has none (HL8): INI as Git's config files, .env as shell.
    @Test func iniAndEnv() {
        let ini = "; settings\n[server]\nhost = example.com\ndebug = true\nname = \"Night Shift\"\n"
        #expect(color(of: "server", in: ini, .ini) == "#E7CE57")
        #expect(color(of: "host", in: ini, .ini) == "#50B4D8")
        #expect(color(of: "example", in: ini, .ini) == "#50B4D8")
        #expect(color(of: "true", in: ini, .ini) == "#EF7C2B")
        #expect(color(of: "settings", in: ini, .ini) == "#848484")
        #expect(color(of: "\"Night", in: ini, .ini) == "#F8F8F2")
        let env = "export API_KEY=\"abc123\"\nPORT=8080\n# local only\n"
        let (language, root) = SyntaxLanguage.detect(fileName: ".env")!
        #expect(color(of: "PORT", in: env, language, root: root) == "#78BC65")
        #expect(color(of: "abc123", in: env, language, root: root) == "#50B4D8")
        #expect(color(of: "8080", in: env, language, root: root) == "#EF7C2B")
        #expect(color(of: "local", in: env, language, root: root) == "#848484")
    }

    /// Swift, whose colors are Nib's own (HL8): Sublime's scopes for the same things in its other
    /// languages, so a scheme colors them alike (a class's name as Python's, a struct's plain as
    /// Rust's, call labels as Python's keyword arguments, attributes as Java's annotations).
    @Test func swiftsOwnColors() {
        let swift = #"""
        import SwiftUI

        /// One feed's store.
        @MainActor
        final class FeedStore: ObservableObject {
            struct Row { let id: UUID }
            static let pageSize = 20

            func load(_ url: URL, retries: Int = 3) async {
                defer { done = true }
                let fresh = try await source.episodes(for: url)
                rows = fresh.filter { !$0.title.isEmpty }
                print("try \(attempt): timed out")
                let label = Text("Hi")
            }
        }
        """#
        #expect(color(of: "final", in: swift, .swift) == "#EC475D")
        #expect(color(of: "FeedStore", in: swift, .swift) == "#E7CE57")
        #expect(color(of: "Row", in: swift, .swift) == "#F8F8F2")
        #expect(color(of: "ObservableObject", in: swift, .swift) == "#50B4D8")
        #expect(color(of: "SwiftUI", in: swift, .swift) == "#78BC65")   // as Python's imported names
        #expect(color(of: "load", in: swift, .swift) == "#E7CE57")
        #expect(color(of: "retries", in: swift, .swift) == "#EF7C2B")
        #expect(color(of: "for:", in: swift, .swift) == "#EF7C2B")
        #expect(color(of: "filter", in: swift, .swift) == "#78BC65")
        #expect(color(of: "$0", in: swift, .swift) == "#EF7C2B")
        #expect(color(of: "print", in: swift, .swift) == "#50B4D8")
        #expect(color(of: "defer", in: swift, .swift) == "#EC475D")
        #expect(color(of: "@", in: swift, .swift) == "#F8F8F2")
        #expect(color(of: "MainActor", in: swift, .swift) == "#78BC65")
        #expect(color(of: "timed", in: swift, .swift) == "#50B4D8")
        #expect(color(of: "\\(", in: swift, .swift) == "#F8F8F2")
        #expect(color(of: "attempt", in: swift, .swift) == "#78BC65")
        #expect(color(of: "Text", in: swift, .swift) == "#50B4D8")
        #expect(color(of: "20", in: swift, .swift) == "#EF7C2B")
        #expect(color(of: "feed's", in: swift, .swift) == "#848484")
    }

    @Test func sublimesScopes() {
        #expect(color(of: "const", in: "const x = 1;", .javascript) == "#EC475D")
        #expect(color(of: "go", in: "function go(a) { return a; }", .javascript) == "#E7CE57")
        #expect(color(of: "go", in: "go(1);", .javascript) == "#78BC65")
        #expect(color(of: "key", in: #"{"key": 1}"#, .json) == "#50B4D8")   // a string, as in Sublime 4 (HL7)
        #expect(color(of: "{", in: "a { color: red; }", .css) == "#F8F8F2")
        #expect(color(of: "Title", in: "# Title\n", .markdown) == "#E7CE57")
        // XML: tag names red, attribute names yellow, values cyan, a namespace's colon plain,
        // entities orange, comments grey, CDATA a string, a DOCTYPE's root name green.
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE rss SYSTEM "rss.dtd">
        <rss xmlns:itunes="http://example.com/ns">
          <!-- a comment -->
          <itunes:image href="cover.jpg"/>
          <title>Tea &amp; toast &#8217;</title>
          <notes><![CDATA[<b>raw</b>]]></notes>
        </rss>
        """
        #expect(color(of: "rss xmlns", in: xml, .xml) == "#EC475D")
        #expect(color(of: "itunes:image", in: xml, .xml) == "#EC475D")
        #expect(color(of: ":image", in: xml, .xml) == "#F8F8F2")
        #expect(color(of: "href", in: xml, .xml) == "#E7CE57")
        #expect(color(of: "cover", in: xml, .xml) == "#50B4D8")
        #expect(color(of: "amp;", in: xml, .xml) == "#EF7C2B")
        #expect(color(of: "8217", in: xml, .xml) == "#EF7C2B")
        #expect(color(of: "#8217", in: xml, .xml) == "#F8F8F2")   // &# is the entity's mark
        #expect(color(of: "a comment", in: xml, .xml) == "#848484")
        #expect(color(of: "<b>raw", in: xml, .xml) == "#50B4D8")
        #expect(color(of: "rss SYSTEM", in: xml, .xml) == "#78BC65")
        #expect(color(of: "Tea", in: xml, .xml) == "#F8F8F2")
        // An end tag the parse can't place while a tag is being typed keeps its name's color.
        let typing = "<rss>\n  <item>\n    <enclo\n  </item>\n</rss>\n"
        #expect(color(of: "rss>\n", in: typing, .xml) == "#EC475D")
        #expect(color(of: "item>\n</rss", in: typing, .xml) == "#EC475D")
    }

    @Test func embeddedLanguagesSitInsideTheirHost() {
        let html = "<script>const x = 1;</script><style>a { color: red; }</style>"
        let runs = Highlighter.runs(html, language: .html)
        let inScript = runs.first { NSLocationInRange((html as NSString).range(of: "const").location, $0.range) }!
        #expect(inScript.scopes.starts(with: ["text.html.basic", "source.js.embedded.html"]))
        let md = "Text\n\n```bash\nssh me\n```\n"
        #expect(color(of: "ssh", in: md, .markdown) == "#78BC65")   // a command, not the fence's green code
        let fenced = "Text\n\n```xml\n<feed lang=\"en\">x</feed>\n```\n"
        let tag = Highlighter.runs(fenced, language: .markdown).first { NSLocationInRange((fenced as NSString).range(of: "feed").location, $0.range) }!
        #expect(tag.scopes.contains("markup.raw.code-fence.xml.markdown-gfm") && tag.scopes.contains("text.xml"))
        #expect(color(of: "feed", in: fenced, .markdown) == "#EC475D")
        #expect(color(of: "lang", in: fenced, .markdown) == "#E7CE57")
    }

    /// HL7's bar, against the harness's last dump from Sublime.
    @Test func fidelityOnTheReferenceFiles() throws {
        let folder = repository.appendingPathComponent("fidelity/sublime")
        let dumps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        try #require(!dumps.isEmpty, "no Sublime dump: run fidelity/run.sh")
        var same = 0, total = 0
        var perFile: [String: (same: Int, total: Int)] = [:]   // each file holds the bar too (21 of them)
        for dump in dumps {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as! [String: Any]
            let text = json["text"] as! String
            let (language, root) = try #require(SyntaxLanguage.detect(fileName: json["file"] as! String, firstLine: text.components(separatedBy: "\n").first))
            let scalars = Array(text.unicodeScalars)
            var utf16At = [0]
            for scalar in scalars { utf16At.append(utf16At.last! + scalar.utf16.count) }
            var expected = [String](repeating: theme.foreground.hex, count: scalars.count)
            for token in json["tokens"] as! [[Any]] {
                for i in (token[0] as! Int)..<min(token[1] as! Int, scalars.count) { expected[i] = (token[3] as? String)?.uppercased() ?? theme.foreground.hex }
            }
            var got = [String](repeating: theme.foreground.hex, count: utf16At.last!)
            for (range, style) in Highlighter.styles(text, language: language, root: root, theme: theme) {
                for i in range.location..<min(NSMaxRange(range), got.count) { got[i] = style.foreground.hex }
            }
            var fileSame = 0, fileTotal = 0
            for (i, scalar) in scalars.enumerated() where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                fileTotal += 1
                if expected[i] == got[utf16At[i]] { fileSame += 1 }
            }
            same += fileSame
            total += fileTotal
            perFile[json["file"] as! String] = (fileSame, fileTotal)
        }
        let share = 100 * Double(same) / Double(total)
        #expect(share >= 98, "fidelity \(share)% (HL7 wants 98%)")
        for (name, file) in perFile {
            #expect(100 * Double(file.same) / Double(file.total) >= 98, "\(name): \(file.same) of \(file.total)")
        }
    }
}

@Suite struct TagMatchTests {
    @Test func theInnermostElementsTags() async {
        let html = "<div class=\"a\">\n  <p>Some <b>bold</b> text</p>\n  <br>\n</div>\n"
        let ns = html as NSString
        let document = SyntaxDocument(language: .html, root: "text.html.basic")
        await document.update(html)
        func names(_ marker: String, _ shift: Int = 0) async -> [String] {
            await document.enclosingTagNames(at: ns.range(of: marker).location + shift).map { "\(ns.substring(with: $0))@\($0.location)" }
        }
        let p = ns.range(of: "<p>").location + 1, pEnd = ns.range(of: "</p>").location + 2
        #expect(await names("Some") == ["p@\(p)", "p@\(pEnd)"])
        #expect(await names("bold") == ["b@\(ns.range(of: "<b>").location + 1)", "b@\(ns.range(of: "</b>").location + 2)"])
        #expect(await names("<br>", 1).first == "div@1")   // a void element has no end tag: the element round it
        #expect(await document.enclosingTagNames(at: ns.length).isEmpty)
    }

    @Test func xmlElementsTags() async {
        let xml = "<rss>\n  <itunes:category text=\"Tech\">\n    <itunes:category text=\"Software\"/>\n  </itunes:category>\n</rss>\n"
        let ns = xml as NSString
        let document = SyntaxDocument(language: .xml, root: "text.xml")
        await document.update(xml)
        func names(_ marker: String, _ shift: Int = 0) async -> [String] {
            await document.enclosingTagNames(at: ns.range(of: marker).location + shift).map { "\(ns.substring(with: $0))@\($0.location)" }
        }
        let open = ns.range(of: "itunes:category").location, close = ns.range(of: "</itunes:category>").location + 2
        #expect(await names("Tech") == ["itunes:category@\(open)", "itunes:category@\(close)"])
        // A self-closing element has no end tag: the element round it.
        #expect(await names("Software") == ["itunes:category@\(open)", "itunes:category@\(close)"])
        #expect(await names("</rss>", 2) == ["rss@1", "rss@\(ns.range(of: "</rss>").location + 2)"])
    }
}
