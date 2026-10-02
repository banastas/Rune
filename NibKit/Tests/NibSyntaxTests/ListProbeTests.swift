// A probe (temporary): how a numbered list like the user's is scoped.
import Foundation
import Testing
@testable import NibSyntax

@Suite struct ListProbeTests {
    static let titles = ["Creative Production: Knowing Which Ideas to Cut", "Why Smart Teams Struggle to Decide", "Creative Reviews: Judge the Work, Not the Intention",
                         "Client Feedback: Hearing the Anxiety Behind the Notes", "Creative Decisions: Make a Recommendation and Commit"]

    static func list(_ count: Int) -> String {
        (1...count).map { "\($0). \(titles[($0 - 1) % titles.count]) | The Show Ep. \($0)\n" }.joined()
    }

    static func describe(_ text: String, _ runs: [ScopeRun], from: Int) -> String {
        let ns = text as NSString
        var out = ""
        var lineStart = from
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let marker = runs.first { NSLocationInRange(line.location, $0.range) }?.scopes.last ?? "-"
            let middle = runs.first { NSLocationInRange(line.location + 6, $0.range) }?.scopes.last ?? "-"
            out += "\(ns.substring(with: NSRange(location: line.location, length: min(12, line.length))).debugDescription) marker: \(marker) · text: \(middle)\n"
            lineStart = NSMaxRange(line)
        }
        return out
    }

    /// Types `typed` at the end of `before`, a character at a time, the document updated after
    /// each (as the editor does after a pause, here after every key), then compares with a fresh parse.
    func typing(_ before: String, _ typed: String, limits: SyntaxDocument.Limits?, every: Int) async -> String {
        let document = limits.map { SyntaxDocument(language: .markdown, root: "text.html.markdown", limits: $0) } ?? SyntaxDocument(language: .markdown, root: "text.html.markdown")
        var text = before
        await document.update(text)
        var n = 0
        for character in typed {
            text.append(character)
            n += 1
            if n % every == 0 { await document.update(text) }
        }
        await document.update(text)
        let start = (before as NSString).length
        let window = NSRange(location: start, length: (text as NSString).length - start)
        let got = await document.runs(in: window)
        let fresh = Highlighter.runs(text, language: .markdown, root: "text.html.markdown", in: window)
        return got == fresh ? "SAME\n" : "DIFFERENT\n" + "got:\n" + Self.describe(text, got, from: start) + "fresh:\n" + Self.describe(text, fresh, from: start)
    }

    @Test func typedIntoASmallText() async {
        let before = "Some notes before.\n\n"
        for every in [1, 3, 7, 25] {
            print("SMALL every \(every): " + (await typing(before, Self.list(17), limits: nil, every: every)))
        }
    }

    @Test func typedIntoABigText() async {
        // A big text, parsed a stretch at a time (small limits make 60K big).
        var before = "# Notes\n\n"
        var n = 0
        while before.utf16.count < 60_000 { n += 1; before += n % 5 == 0 ? "- item \(n)\n- another\n\n" : "A paragraph \(n) about things, with `code` and **bold**.\n\n" }
        let limits = SyntaxDocument.Limits(whole: 3_000, chunk: 2_500, lead: 500, trail: 1_000, margin: 400)
        for every in [1, 3, 7, 25] {
            print("BIG every \(every): " + (await typing(before, Self.list(17), limits: limits, every: every)))
        }
    }

    /// As `typing`, but at `at` in the middle of `text`, with text after it.
    func typingInside(_ text: String, at: Int, _ typed: String, limits: SyntaxDocument.Limits?, every: Int) async -> String {
        let document = limits.map { SyntaxDocument(language: .markdown, root: "text.html.markdown", limits: $0) } ?? SyntaxDocument(language: .markdown, root: "text.html.markdown")
        let ns = text as NSString
        var head = ns.substring(to: at)
        let tail = ns.substring(from: at)
        await document.update(head + tail)
        // The view stays round the typing, as in the editor: ask for its window now and then.
        var n = 0
        for character in typed {
            head.append(character)
            n += 1
            if n % every == 0 {
                await document.update(head + tail)
                let h = (head as NSString).length
                _ = await document.runs(in: NSRange(location: max(0, h - 12_000), length: 24_000).intersection(NSRange(location: 0, length: (head + tail as NSString).length)) ?? NSRange(location: 0, length: 0))
            }
        }
        let final = head + tail
        await document.update(final)
        let window = NSRange(location: at, length: (typed as NSString).length)
        let got = await document.runs(in: window)
        let fresh = Highlighter.runs(final, language: .markdown, root: "text.html.markdown", in: window)
        return got == fresh ? "SAME\n" : "DIFFERENT\n" + "got:\n" + Self.describe(final, got, from: at) + "fresh:\n" + Self.describe(final, fresh, from: at)
    }

    static func bigText(_ size: Int) -> String {
        var text = "# Notes\n\n", n = 0
        while text.utf16.count < size {
            n += 1
            switch n % 7 {
            case 0: text += "- item \(n)\n- another\n\n"
            case 1: text += "## Heading \(n)\n\n"
            case 2: text += "1. first \(n)\n2. second\n\n"
            case 3: text += "```js\nconst a = \(n);\n```\n\n"
            default: text += "A paragraph \(n) about things, with `code` and **bold**.\nIt wraps onto a second line.\n\n"
            }
        }
        return text
    }

    @Test func typedInsideABigText() async {
        let small = SyntaxDocument.Limits(whole: 3_000, chunk: 2_500, lead: 500, trail: 1_000, margin: 400)
        let text = Self.bigText(60_000)
        // At a paragraph's start, in the middle: a blank line before the list, and the next paragraph after.
        let ns = text as NSString, at = ns.range(of: "A paragraph ", range: NSRange(location: ns.length / 2, length: ns.length / 2)).location
        for every in [1, 3, 7, 25] {
            print("INSIDE small limits, every \(every): " + (await typingInside(text, at: at, Self.list(17) + "\n", limits: small, every: every)))
        }
    }

    @Test func typedInsideARealSizeText() async {
        let text = Self.bigText(2_400_000)
        let ns = text as NSString, at = ns.range(of: "A paragraph ", range: NSRange(location: ns.length / 5, length: ns.length / 2)).location
        for every in [5, 25] {
            print("INSIDE 2.4 MB, every \(every): " + (await typingInside(text, at: at, Self.list(17) + "\n", limits: nil, every: every)))
        }
    }

    @Test func wholeParse() {
        let text = "Some notes before.\n\n" + Self.list(8)
        let runs = Highlighter.runs(text, language: .markdown, root: "text.html.markdown")
        print("WHOLE:\n" + Self.describe(text, runs, from: 20))
    }
}
