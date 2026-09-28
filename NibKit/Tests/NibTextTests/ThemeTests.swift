// Color schemes (PRD HL2, HL10): An Old Hope · Nib's rules resolved as Sublime resolves
// them, and TextMate scope selectors: descendants, unions, exclusions, grouping, ranking.

import Foundation
import Testing

@testable import NibText

@Suite struct ThemeTests {
    /// The built-in scheme, from the repository.
    static let theme: Theme = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("themes/an-old-hope-nib.tmTheme")
        return try! Theme(tmTheme: Data(contentsOf: url))
    }()

    func fg(_ scopes: String) -> String { Self.theme.style(for: scopes).foreground.hex }

    @Test func readsGlobalsAndRules() {
        #expect(Self.theme.background.hex == "#1C1D21")
        #expect(Self.theme.foreground.hex == "#F8F8F2")
        #expect(Self.theme.globals["lineHighlight"] == "#272B34")
        #expect(Self.theme.rules.count == 42)
    }

    @Test func plainRules() {
        #expect(fg("source.js comment.line.double-slash.js") == "#848484")
        #expect(fg("source.js string.quoted.double.js") == "#50B4D8")
        #expect(fg("source.js constant.numeric.integer.decimal.js") == "#EF7C2B")
        #expect(fg("source.js keyword.control.conditional.js") == "#EC475D")
        #expect(fg("source.js meta.function.js entity.name.function.js") == "#E7CE57")
        #expect(fg("source.js") == "#F8F8F2")   // nothing matches: the scheme's text color
    }

    @Test func theMoreSpecificRuleWins() {
        // storage.type beats storage; entity.other.attribute-name.class.css beats entity.other.attribute-name.
        let type = Self.theme.style(for: "source.js storage.type.function.js")
        #expect(type.foreground.hex == "#50B4D8" && type.italic)
        #expect(fg("source.js storage.modifier.js") == "#EC475D")
        #expect(fg("source.css meta.selector.css entity.other.attribute-name.class.css") == "#E7CE57")
        #expect(fg("text.html.basic meta.tag entity.other.attribute-name.html") == "#E7CE57")
    }

    @Test func descendantRulesNeedTheirContext() {
        // An Old Hope's JSON-key rule targets Sublime 3's scopes (HL7): Sublime 4's keys stay strings.
        #expect(fg("source.json meta.structure.dictionary.key.json string.quoted.double.json") == "#E7CE57")
        #expect(fg("source.json meta.mapping.key.json string.quoted.double.json") == "#50B4D8")
    }

    @Test func embeddedSourceLosesToDeeperRules() {
        let fence = "text.html.markdown markup.raw.code-fence.markdown-gfm source.js"
        #expect(fg(fence) == "#F8F8F2")                                  // Embedded Source
        #expect(fg(fence + " keyword.control.js") == "#EC475D")          // but a keyword in it is a keyword
        #expect(fg("text.html.markdown markup.raw.inline.markdown") == "#78BC65")
    }

    @Test func eachPropertyFromItsOwnBestRule() {
        let invalid = Self.theme.style(for: "source.js invalid.illegal.js")
        #expect(invalid.foreground.hex == "#1C1D21" && invalid.background?.hex == "#EC475D")
        let heading = Self.theme.style(for: "text.html.markdown markup.heading.1.markdown entity.name.section.markdown")
        #expect(heading.foreground.hex == "#E7CE57" && heading.bold)
        // A rule with fontStyle "" sets it to plain: variable.parameter is italic, but a plain variable isn't.
        #expect(Self.theme.style(for: "source.js variable.parameter.function.js").italic)
        #expect(!Self.theme.style(for: "source.js variable.other.readwrite.js").italic)
    }

    @Test func aRepeatedScopeMatchesAtItsInnermost() {
        // `deploy` in "${1:-deploy}": a word in an expansion in a string is a string again.
        #expect(fg("source.shell.zsh string.quoted.double.shell variable.other.readwrite.shell string.unquoted.shell") == "#50B4D8")
    }

    @Test func selectors() {
        let stack = ["source.js", "meta.function.js", "string.quoted.double.js"]
        #expect(ScopeSelector("string").match(stack) != nil)
        #expect(ScopeSelector("strin").match(stack) == nil)                       // whole segments only
        #expect(ScopeSelector("source string").match(stack) != nil)
        #expect(ScopeSelector("string source").match(stack) == nil)               // order matters
        #expect(ScopeSelector("comment, string").match(stack) != nil)             // union
        #expect(ScopeSelector("string - meta.function").match(stack) == nil)      // exclusion
        #expect(ScopeSelector("string - comment").match(stack) != nil)
        #expect(ScopeSelector("(comment, string) - meta.function").match(stack) == nil)   // grouping
        #expect(ScopeSelector("source (comment, string)").match(stack) != nil)
        // Deeper beats shallower, and more segments beat fewer at the same depth.
        #expect(ScopeSelector("string").match(stack)! > ScopeSelector("source.js").match(stack)!)
        #expect(ScopeSelector("string.quoted").match(stack)! > ScopeSelector("string").match(stack)!)
    }

    @Test func colors() {
        #expect(RGBA(hex: "#1C1D21")?.hex == "#1C1D21")
        #expect(RGBA(hex: "#00000080")?.hex == "#00000080")
        #expect(RGBA(hex: "#fff")?.hex == "#FFFFFF")
        #expect(RGBA(hex: "red") == nil)
    }
}

/// Every scope Sublime reported for the reference files (fidelity/sublime/, from the harness)
/// gets the same colors from Nib's resolution of the scheme as from Sublime's own.
@Suite struct ThemeAgainstSublimeTests {
    @Test func sameColorsForEveryScopeSublimeReported() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fidelity/sublime")
        let dumps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        try #require(!dumps.isEmpty, "no Sublime dump: run fidelity/run.sh")
        var checked = 0, wrong: [String] = []
        for dump in dumps {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as! [String: Any]
            for token in json["tokens"] as! [[Any]] {
                let scope = token[2] as! String
                let style = ThemeTests.theme.style(for: scope)
                let fg = (token[3] as? String)?.uppercased(), bg = (token[4] as? String)?.uppercased()
                let italic = token[6] as? Bool ?? false
                checked += 1
                if style.foreground.hex != fg || (bg != nil && bg != Self.backgroundHex && style.background?.hex != bg) || style.italic != italic {
                    wrong.append("\(scope): Sublime \(fg ?? "-") \(bg ?? "-") \(italic ? "italic" : ""), Nib \(style.foreground.hex) \(style.background?.hex ?? "-") \(style.italic ? "italic" : "")")
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(checked): \(Array(Set(wrong)).sorted().prefix(12).joined(separator: "\n"))")
    }

    static let backgroundHex = "#1C1D21"
}
