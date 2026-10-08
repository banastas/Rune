// A numbered list typed in Markdown (the user's, 2026-10-02): the tree kept across the edits
// colors it as a parse of the whole does, key by key or a word at a time, at a small text's end
// and in a big one parsed a stretch at a time. (The colors the user saw were the screen's, not
// these: `Editor.redrawText`.)

import Foundation
import Testing

@testable import NibSyntax

@Suite struct ListTypingTests {
    static let titles = ["Creative Production: Knowing Which Ideas to Cut", "Why Smart Teams Struggle to Decide",
                         "Creative Reviews: Judge the Work, Not the Intention", "Client Feedback: Hearing the Anxiety Behind the Notes"]

    static func list(_ count: Int) -> String {
        (1...count).map { "\($0). \(titles[($0 - 1) % titles.count]) | The Show Ep. \($0)\n" }.joined()
    }

    /// `typed` added at the end of `before`, the document told after every `every` keys.
    func typing(_ before: String, _ typed: String, limits: SyntaxDocument.Limits?, every: Int) async -> (got: [ScopeRun], fresh: [ScopeRun]) {
        let document = limits.map { SyntaxDocument(language: .markdown, root: "text.html.markdown", limits: $0) }
            ?? SyntaxDocument(language: .markdown, root: "text.html.markdown")
        var text = before
        await document.update(text)
        for (n, character) in typed.enumerated() {
            text.append(character)
            if (n + 1) % every == 0 { await document.update(text) }
        }
        await document.update(text)
        let start = (before as NSString).length
        let window = NSRange(location: start, length: (text as NSString).length - start)
        return (await document.runs(in: window), Highlighter.runs(text, language: .markdown, root: "text.html.markdown", in: window))
    }

    @Test func everyItemIsAListItem() {
        let text = "Some notes before.\n\n" + Self.list(17)
        let runs = Highlighter.runs(text, language: .markdown, root: "text.html.markdown")
        let ns = text as NSString
        var line = NSRange(location: 20, length: 0)
        while line.location < ns.length {
            line = ns.lineRange(for: NSRange(location: line.location, length: 0))
            for at in [line.location, line.location + 5] {
                #expect(runs.first { NSLocationInRange(at, $0.range) }?.scopes.last == "markup.list.numbered.markdown", "\(ns.substring(with: line))")
            }
            line.location = NSMaxRange(line)
        }
    }

    @Test(arguments: [1, 3, 7, 25]) func typedAtTheEndOfASmallText(every: Int) async {
        let (got, fresh) = await typing("Some notes before.\n\n", Self.list(17), limits: nil, every: every)
        #expect(got == fresh)
    }

    @Test(arguments: [1, 7]) func typedAtTheEndOfABigText(every: Int) async {
        var before = "# Notes\n\n", n = 0
        while before.utf16.count < 60_000 {
            n += 1
            before += n % 5 == 0 ? "- item \(n)\n- another\n\n" : "A paragraph \(n) about things, with `code` and **bold**.\n\n"
        }
        let (got, fresh) = await typing(before, Self.list(17), limits: WindowedTests.small, every: every)
        #expect(got == fresh)
    }
}
