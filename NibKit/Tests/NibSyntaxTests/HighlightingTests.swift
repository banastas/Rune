// Highlighting (PRD HL1, HL7, HL10): languages found by name and shebang, scopes as Sublime
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
    }

    @Test func sublimesScopes() {
        #expect(color(of: "const", in: "const x = 1;", .javascript) == "#EC475D")
        #expect(color(of: "go", in: "function go(a) { return a; }", .javascript) == "#E7CE57")
        #expect(color(of: "go", in: "go(1);", .javascript) == "#78BC65")
        #expect(color(of: "key", in: #"{"key": 1}"#, .json) == "#50B4D8")   // a string, as in Sublime 4 (HL7)
        #expect(color(of: "{", in: "a { color: red; }", .css) == "#F8F8F2")
        #expect(color(of: "Title", in: "# Title\n", .markdown) == "#E7CE57")
    }

    @Test func embeddedLanguagesSitInsideTheirHost() {
        let html = "<script>const x = 1;</script><style>a { color: red; }</style>"
        let runs = Highlighter.runs(html, language: .html)
        let inScript = runs.first { NSLocationInRange((html as NSString).range(of: "const").location, $0.range) }!
        #expect(inScript.scopes.starts(with: ["text.html.basic", "source.js.embedded.html"]))
        let md = "Text\n\n```bash\nssh me\n```\n"
        #expect(color(of: "ssh", in: md, .markdown) == "#78BC65")   // a command, not the fence's green code
    }

    /// HL7's bar, against the harness's last dump from Sublime.
    @Test func fidelityOnTheReferenceFiles() throws {
        let folder = repository.appendingPathComponent("fidelity/sublime")
        let dumps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        try #require(!dumps.isEmpty, "no Sublime dump: run fidelity/run.sh")
        var same = 0, total = 0
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
            for (i, scalar) in scalars.enumerated() where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                total += 1
                if expected[i] == got[utf16At[i]] { same += 1 }
            }
        }
        let share = 100 * Double(same) / Double(total)
        #expect(share >= 98, "fidelity \(share)% (HL7 wants 98%)")
    }
}
