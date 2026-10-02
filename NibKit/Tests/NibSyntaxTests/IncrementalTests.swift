// Incremental highlighting (PRD §6.3, §6.5): the styles of any stretch are the whole text's,
// cut to that stretch; and a tree kept across edits is the tree a fresh parse gives.

import Foundation
import Testing

@testable import NibSyntax
@testable import NibText

@Suite struct IncrementalTests {
    static let references: [(name: String, text: String, language: SyntaxLanguage, root: String)] = {
        let folder = repository.appendingPathComponent("fidelity/reference")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
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
        try #require(Self.references.count == 9)   // six from HL1, three XML (HL8)
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

    @Test func editedTreesMatchFreshParses() async throws {
        var generator = SplitMix(seed: 20260928)
        for file in Self.references {
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
                #expect(await document.treeDescription == fresh, "\(file.name) step \(step): the tree differs from a fresh parse")
                let length = (text as NSString).length
                #expect(await document.runs(in: NSRange(location: 0, length: length)) == Highlighter.runs(text, language: file.language, root: file.root),
                        "\(file.name) step \(step): the runs differ")
            }
        }
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
