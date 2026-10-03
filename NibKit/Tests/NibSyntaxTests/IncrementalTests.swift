// Incremental highlighting (PRD §6.3, §6.5): the styles of any stretch are the whole text's,
// cut to that stretch; and a tree kept across edits is the tree a fresh parse gives.

import Foundation
import Testing

@testable import NibSyntax
@testable import NibText

@Suite struct IncrementalTests {
    /// Sublime's reference files, and those in Nib's own colors (Swift, INI, .env; HL8).
    static let references: [(name: String, text: String, language: SyntaxLanguage, root: String)] = {
        let files = ["fidelity/reference", "fidelity/own"].flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: repository.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? []
        }
        return files.sorted { $0.path < $1.path }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let (language, root) = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: text.components(separatedBy: "\n").first) else { return nil }
            return (url.lastPathComponent, text, language, root)
        }
    }()

    /// The whole text's runs, cut to `window`.
    func clipped(_ runs: [ScopeRun], to window: NSRange) -> [ScopeRun] {
        runs.compactMap { run in
            let part = NSIntersectionRange(run.range, window)
            return part.length > 0 ? ScopeRun(range: part, scopes: run.scopes) : nil
        }
    }

    @Test func aWindowIsTheWholeCutToIt() throws {
        try #require(Self.references.count == 33)   // six from HL1, three XML, twelve, nine and three more (HL8)
        var windows = 0
        for file in Self.references {
            let whole = Highlighter.runs(file.text, language: file.language, root: file.root)
            let length = (file.text as NSString).length
            // Windows of several sizes, starting everywhere (mid-token, inside a fence or a script).
            for size in [1, 17, 240, 1_000, length] {
                for start in stride(from: 0, to: max(1, length), by: max(1, length / 23)) {
                    let window = NSRange(location: start, length: min(size, length - start))
                    let part = Highlighter.runs(file.text, language: file.language, root: file.root, in: window)
                    #expect(part == clipped(whole, to: window), "\(file.name) \(window)")
                    windows += 1
                }
            }
        }
        #expect(windows > 500)
    }

    /// Where an edit leaves code a parser has to repair (an ERROR or MISSING node in the fresh
    /// parse), tree-sitter's repair can come out differently from a tree it reuses than from
    /// nothing: its promise is the same tree for code that parses cleanly. So a tree that differs
    /// is a failure unless the code is broken there; those are counted, and must stay rare.
    /// (Seen 2026-10-02: `<b>` typed into a JavaScript function's parameters.) Each file's edits
    /// come from its own generator, so adding a reference file doesn't change the others'.
    @Test func editedTreesMatchFreshParses() async throws {
        var compared = 0, repaired = 0
        for file in Self.references {
            var generator = SplitMix(seed: 20260928 ^ file.name.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 })
            let document = SyntaxDocument(language: file.language, root: file.root)
            var text = file.text
            #expect(await document.update(text) == .whole)
            #expect(await document.update(text) == .unchanged)
            for step in 0..<40 {
                let ns = text as NSString
                let at = Int(generator.next() % UInt64(ns.length + 1))
                let cut = min(ns.length - at, Int(generator.next() % 12))
                let insert = ["", "x", "\n", "\"", "{", "}", "<b>", "`", "# ", "$(", "é", "🙂", "/*", "*/", "```\n"][Int(generator.next() % 15)]
                text = ns.replacingCharacters(in: NSRange(location: at, length: cut), with: insert)
                let parse = await document.update(text)
                if case .whole = parse { Issue.record("\(file.name) step \(step): a whole parse") }
                let fresh = Highlighter.tree(text, language: file.language)
                let kept = await document.treeDescription
                if kept != fresh, fresh.contains("(ERROR") || fresh.contains("(MISSING") { repaired += 1; continue }
                compared += 1
                #expect(kept == fresh, "\(file.name) step \(step): the tree differs from a fresh parse")
                let length = (text as NSString).length
                #expect(await document.runs(in: NSRange(location: 0, length: length)) == Highlighter.runs(text, language: file.language, root: file.root),
                        "\(file.name) step \(step): the runs differ")
            }
        }
        // 33 files of 40 edits: all but a few compared (repairs that differ are rare; none on 2026-10-02).
        #expect(compared >= 1_250, "compared \(compared), repaired differently \(repaired)")
    }

    @Test func theChangeIsFound() async {
        let document = SyntaxDocument(language: .javascript, root: "source.js")
        await document.update("const a = 1;\nconst b = 2;\n")
        #expect(await document.update("const a = 1;\nconst bee = 2;\n") == .incremental(NSRange(location: 20, length: 2)))
        #expect(await document.update("const a = 1;\n") == .incremental(NSRange(location: 13, length: 0)))
    }

    @Test func stylesComeFromTheScheme() async {
        let text = "function add(note) { return note; }\n"
        let document = SyntaxDocument(language: .javascript, root: "source.js")
        await document.update(text)
        let theme = Theme.anOldHopeNib
        let styles = await document.styles(in: NSRange(location: 0, length: (text as NSString).length), theme: theme)
        #expect(styles.map(\.range) == Highlighter.styles(text, language: .javascript, root: "source.js", theme: theme).map(\.range))
        let note = (text as NSString).range(of: "note").location
        #expect(styles.first { NSLocationInRange(note, $0.range) }?.style.italic == true)
    }
}

/// A small, seeded generator, so a failing edit sequence can be replayed.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
