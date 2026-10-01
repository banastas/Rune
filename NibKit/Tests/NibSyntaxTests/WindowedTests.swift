// Big texts (PRD §6.3, §6.5): a tree of the stretch around the view only, parsed from a place
// where a parse of the whole is in its starting state too, colors exactly as a tree of the
// whole does, through scrolling, jumps and edits anywhere.

import Foundation
import Testing
import SwiftTreeSitter

@testable import NibSyntax
@testable import NibText

@Suite struct WindowedTests {
    /// Small limits, so a text of a few tens of K is big and is cut into many stretches.
    static let small = SyntaxDocument.Limits(whole: 3_000, chunk: 2_500, lead: 500, trail: 1_000, margin: 400)

    struct Sample: CustomStringConvertible {
        var name: String
        var language: SyntaxLanguage
        var root: String
        /// The text's constructs, in order (a paragraph, a list, a function), so an edit can add or
        /// take out a whole one.
        var parts: [String]
        var text: String { parts.joined() }
        var description: String { name }
    }

    /// Texts with what tends to go wrong when a parse starts partway: fences (one with a blank
    /// line in it), HTML blocks that span blank lines, lazy lines, setext headings, indented code,
    /// the harness's runs with no blank lines; template strings and comments over several lines.
    static func samples(size: Int, seed: UInt64) -> [Sample] {
        var g = SplitMix(seed: seed)
        func pick(_ k: Int) -> Int { Int(g.next() % UInt64(k)) }
        func build(_ first: [String] = [], _ last: [String] = [], _ next: (Int) -> String) -> [String] {
            var parts = first, length = 0, n = 0
            while length < size {
                n += 1
                let part = next(n)
                parts.append(part)
                length += (part as NSString).length
            }
            return parts + last
        }

        let md = build(["# Notes\n\n"]) { n in
            switch pick(16) {
            case 0: return "## Heading \(n)\n\n"
            case 1: return "Setext \(n)\n===\n\n"
            case 2: return "Sub \(n)\n---\n\n"
            case 3: return "- item \(n) with `code`\n- another with **bold**\n  continued line\n- third\n\n"
            case 4: return "1. first \(n)\n2. second\n\n   a paragraph in the item\n3. third\n\n"
            case 5: return "> quote \(n) with *em*\nlazy continuation\n> more\n\n"
            case 6: return "```js\nconst a\(n) = `x ${n}`;\n/* c */ function f() { return 1; }\n```\n\n"
            case 7: return "```bash\necho \"\(n)\" | grep x\n\nls -la ~/www\n```\n\n"
            case 8: return "~~~\nplain fenced \(n)\n# not a heading\n~~~\n\n"
            case 9: return "    indented code \(n)\n    more code\n\n"
            case 10: return "<div class=\"x\">\n\n*not* markdown \(n)?\n\n</div>\n\n"
            case 11: return "<!--\ncomment \(n)\n\n- still comment\n-->\n\n"
            case 12: return "| a | b |\n|---|---|\n| \(n) | [link](https://example.com/\(n)) |\n\n"
            case 13: return "***\n\n"
            case 14:
                var run = ""
                for m in 0..<(5 + pick(30)) {
                    run += m % 3 == 0 ? "- item \(n).\(m) with `code` and **bold** text\n" : "Line \(n).\(m): see https://example.com/\(m) and the config.json file.\n"
                }
                return run + "\n"
            default: return "A paragraph \(n) about [a link](https://example.com/\(n)), `code`, **bold** and _em_.\nIt wraps onto a second line.\n\n"
            }
        }

        let js = build { j in
            switch pick(10) {
            case 0: return "/**\n * Docs for \(j).\n * @param {string} a\n */\nfunction documented\(j)(a, b = 2) {\n  return a + b;\n}\n\n"
            case 1: return "class Widget\(j) extends Base {\n  constructor(x) { super(x); this.x = x; }\n  get value() { return this.#v; }\n  #v = \(j);\n  static make() { return new Widget\(j)(1); }\n}\n\n"
            case 2: return "const html\(j) = `\n<div class=\"${cls}\">\n  ${items.map(i => `<li>${i}</li>`).join(\"\")}\n</div>\n`;\n\n"
            case 3: return "/* a block comment \(j)\nfunction notCode() {}\n*/\n\n"
            case 4: return "const re\(j) = /ab+c\\/d/gi, s = 'single', d = \"double \\\" quote\";\n\n"
            case 5: return "export const handler\(j) = async (event) => {\n  const value = event.detail?.value ?? \(j);\n  if (value > 10) { return \"big\"; }\n  for (const x of [1, 2]) console.log(x);\n};\n\n"
            case 6: return "(function () {\n  var inner\(j) = 1;\n  function deep() { return inner\(j); }\n  window.x = deep();\n})();\n\n"
            case 7: return "switch (k\(j)) {\n  case 1: break;\n  default: throw new Error(`bad ${k}`);\n}\n\n"
            case 8: return "import { a\(j) } from \"./mod\(j).js\";\n"
            default: return "// block \(j)\nfunction handler\(j)(event) {\n  const value = event.detail?.value ?? \(j);\n  return value > 10 ? \"big\" : `small ${value}`;\n}\n"
            }
        }

        let css = build { c in
            switch pick(5) {
            case 0: return "/* section \(c)\n   spans lines */\n"
            case 1: return "@media (max-width: 600px) {\n  .card-\(c) { margin: 0 auto 12px; }\n  .x::before { content: \"}\"; }\n}\n"
            case 2: return ":root { --accent-\(c): #ff00aa; }\n"
            default: return ".card-\(c) > .title:hover, #id\(c) a[href^=\"http\"] {\n  color: #ff\(c % 10)0aa;\n  font: 15px/1.5 \"Helvetica Neue\", sans-serif !important;\n}\n"
            }
        }

        let json = build(["[\n"], ["  {}\n]\n"]) { k in
            "  {\"id\": \(k), \"name\": \"item \\\"\(k)\\\"\", \"tags\": [\"a\", \"b\"], \"nested\": {\"ok\": true, \"n\": null, \"x\": -1.5e3}},\n"
        }

        let sh = build(["#!/bin/zsh\n"]) { h in
            switch pick(5) {
            case 0: return "# comment \(h)\nfunction deploy\(h)() {\n  local dir=\"$HOME/www/\(h)\"\n  rsync -av --progress ./dist/ \"$dir\" && echo \"done ${h}\"\n}\n\n"
            case 1: return "if [ -f ~/.zshrc ]; then\n  source ~/.zshrc\nfi\n\n"
            case 2: return "cat <<EOF > /tmp/out\(h)\nheredoc $HOME line\nfunction notReal() {}\nEOF\n\n"
            case 3: return "case \"$1\" in\n  start) echo start ;;\n  *) echo \"usage: $0\" ;;\nesac\n\n"
            default: return "export PATH=\"$HOME/bin:$PATH\"  # path \(h)\nls -la *.txt | grep -v '^d' | wc -l\n\n"
            }
        }

        let html = build(["<!DOCTYPE html>\n<html>\n<head>\n<style>\n.a { color: red; }\n</style>\n</head>\n<body>\n"], ["</body>\n</html>\n"]) { t in
            t % 7 == 0 ? "<script>\nconst x\(t) = `${n}`;\n</script>\n"
                : "<div class=\"card\" id=\"c\(t)\">\n  <p>Text &amp; more \(t)</p>\n  <!-- note -->\n  <a href=\"https://example.com/\(t)\">link</a>\n</div>\n"
        }

        return [Sample(name: "markdown", language: .markdown, root: "text.html.markdown", parts: md),
                Sample(name: "javascript", language: .javascript, root: "source.js", parts: js),
                Sample(name: "css", language: .css, root: "source.css", parts: css),
                Sample(name: "json", language: .json, root: "source.json", parts: json),
                Sample(name: "shell", language: .shell, root: "source.shell.zsh", parts: sh),
                Sample(name: "html", language: .html, root: "text.html.basic", parts: html)]
    }

    /// Whether a fenced block that touches `window` runs on past `end` in a parse of the whole.
    static func cutsAFence(_ text: String, at end: Int, near window: NSRange) -> Bool {
        let parser = Parser()
        guard (try? parser.setLanguage(SyntaxLanguage.markdown.tsLanguage)) != nil, let root = parser.parse(text)?.rootNode else { return false }
        var found = false
        func walk(_ node: Node) {
            guard !found, NSMaxRange(node.range) > window.location, node.range.location < NSMaxRange(window) else { return }
            if node.nodeType == "fenced_code_block", NSMaxRange(node.range) > end, node.range.location < end { found = true }
            node.enumerateChildren { walk($0) }
        }
        walk(root)
        return found
    }

    func clipped(_ runs: [ScopeRun], to window: NSRange) -> [ScopeRun] {
        runs.compactMap { run in
            let part = NSIntersectionRange(run.range, window)
            return part.length > 0 ? ScopeRun(range: part, scopes: run.scopes) : nil
        }
    }

    /// Where two sets of runs first differ, for a failure's message.
    func difference(_ got: [ScopeRun], _ expected: [ScopeRun], in text: String) -> String {
        let ns = text as NSString
        for (a, b) in zip(got, expected) where a != b {
            let at = min(a.range.location, b.range.location)
            let around = ns.substring(with: NSIntersectionRange(NSRange(location: max(0, at - 40), length: 100), NSRange(location: 0, length: ns.length)))
            return "got \(a.range) \(a.scopes.joined(separator: " ")), expected \(b.range) \(b.scopes.joined(separator: " ")) near \(around.debugDescription)"
        }
        return "\(got.count) runs, expected \(expected.count)"
    }

    @Test(arguments: samples(size: 40_000, seed: 20260930))
    func stretchesMatchTheWhole(sample: Sample) async {
        let text = sample.text
        let document = SyntaxDocument(language: sample.language, root: sample.root, limits: Self.small)
        await document.update(text)
        let whole = Highlighter.runs(text, language: sample.language, root: sample.root)
        let length = (text as NSString).length
        var g = SplitMix(seed: 7)
        // Down the text a screen at a time, then jumps, then back up.
        var windows: [NSRange] = []
        for start in stride(from: 0, to: length, by: 650) { windows.append(NSRange(location: start, length: min(700, length - start))) }
        for _ in 0..<40 {
            let start = Int(g.next() % UInt64(length))
            windows.append(NSRange(location: start, length: min(700, length - start)))
        }
        for start in stride(from: length - 700, through: 0, by: -1_700) { windows.append(NSRange(location: start, length: 700)) }
        for window in windows {
            let runs = await document.runs(in: window), expected = clipped(whole, to: window)
            #expect(runs == expected, "\(sample.name) \(window): \(difference(runs, expected, in: text))")
            if runs != expected { break }
        }
        // The tree is of a stretch, not the whole, where the language allows it.
        if sample.language.hasStarts, let slice = await document.sliceRange {
            #expect(slice.length < length / 4, "\(sample.name): a stretch of \(slice.length) of \(length)")
        }
    }

    /// Editing as people do, many times over: an edit or two that can break the syntax (an
    /// opening fence, comment or quote, a cut), then undone; a construct added or taken out
    /// somewhere; the view moving now and then. Whenever the whole text parses cleanly, the
    /// window colors exactly as a parse of the whole does. (While it doesn't, tree-sitter's
    /// repair of a JavaScript error can depend on how much text comes after, so a stretch and the
    /// whole may differ there: random breaks left unfixed showed it, 2026-09-30.)
    @Test(arguments: [(3, "markdown"), (5, "markdown"), (8, "markdown"), (1, "javascript"), (4, "javascript"), (9, "javascript"),
                      (2, "css"), (6, "css")])
    func editsAnywhereKeepItRight(seed: Int, name: String) async {
        let sample = Self.samples(size: 15_000, seed: UInt64(1_000 + seed)).first { $0.name == name }!
        let limits = SyntaxDocument.Limits(whole: 2_000, chunk: 1_500 + seed * 100, lead: 300 + seed * 20, trail: 700, margin: 300)
        let document = SyntaxDocument(language: sample.language, root: sample.root, limits: limits)
        var parts = sample.parts, text = sample.text
        await document.update(text)
        var g = SplitMix(seed: UInt64(seed) &* 7_919 &+ 3)
        func pick(_ k: Int) -> Int { Int(g.next() % UInt64(max(1, k))) }
        let breaks = ["", "x", "word ", "\n", "\n\n", "```\n", "~~~\n", "- ", "> ", "# ", "    ", "`", "**", "<div>\n", "<!--", "-->",
                      "/*", "*/", "{", "}", "(", "\"", "'", "${", "1. ", "---\n", "🙂", "é", "## Title\n\n", "\n- item\n"]
        var view = NSRange(location: 0, length: 500)
        var checked = 0, step = 0
        func check(_ what: String) async {
            step += 1
            let length = (text as NSString).length
            view.location = max(0, min(view.location, length - 1))
            view.length = min(500, length - view.location)
            await document.update(text)
            let runs = await document.runs(in: view)
            let tree = Highlighter.tree(text, language: sample.language)
            guard sample.language == .markdown || !(tree.contains("ERROR") || tree.contains("MISSING")) else { return }
            checked += 1
            let expected = Highlighter.runs(text, language: sample.language, root: sample.root, in: view)
            // A heading's # alone at the very end, as just typed: tree-sitter-markdown reads it as an
            // error when no heading comes before it in the parse (a stretch's can start after one).
            if runs != expected, sample.language == .markdown, text.range(of: "(^|\n)#{1,6} ?$", options: .regularExpression) != nil { return }
            let slice = await document.sliceRange
            // A fence the stretch cuts off (it runs on more than a chunk past the stretch's
            // trail): its code is read up to the cut, so it can differ there.
            if runs != expected, sample.language == .markdown, let slice, Self.cutsAFence(text, at: NSMaxRange(slice), near: view) { return }
            #expect(runs == expected, "\(name) seed \(seed) step \(step) (\(what)), view \(view), stretch \(String(describing: slice)): \(difference(runs, expected, in: text))")
        }
        for _ in 0..<60 {
            switch pick(8) {
            case 0: view.location = pick((text as NSString).length)
            case 1: view.location += 1_200
            case 2: view.location = max(0, view.location - 1_200)
            default: break
            }
            // An edit or two that can break it, then undone.
            var undo: [(range: NSRange, text: String)] = []
            for _ in 0..<(1 + pick(2)) {
                let length = (text as NSString).length
                let at = pick(4) == 0 ? pick(length) : min(length, view.location + pick(view.length + 1))
                let range = NSRange(location: at, length: min(pick(6) == 0 ? pick(400) : pick(6), length - at))
                let insert = breaks[pick(breaks.count)]
                undo.append((NSRange(location: at, length: (insert as NSString).length), (text as NSString).substring(with: range)))
                text = (text as NSString).replacingCharacters(in: range, with: insert)
                await check("a break")
            }
            for (range, old) in undo.reversed() {
                text = (text as NSString).replacingCharacters(in: range, with: old)
                await check("undone")
            }
            // A construct added or taken out.
            let at = pick(parts.count)
            if pick(3) == 0, parts.count > 10 { parts.remove(at: at) } else { parts.insert(sample.parts[pick(sample.parts.count)], at: at) }
            text = parts.joined()
            await check("a construct")
        }
        #expect(checked > 100, "\(name) seed \(seed): only \(checked) steps parsed cleanly to check")
    }

    /// At real sizes (the limits Nib uses, a window as wide as the editor styles), edits as in
    /// `editsAnywhereKeepItRight`: whenever the whole text parses cleanly, the window colors
    /// exactly as a parse of the whole does.
    @Test(arguments: samples(size: 400_000, seed: 20261002).filter(\.language.hasStarts))
    func editsAtRealSizes(sample: Sample) async {
        let document = SyntaxDocument(language: sample.language, root: sample.root)
        var text = sample.text
        await document.update(text)
        var g = SplitMix(seed: 13)
        func pick(_ k: Int) -> Int { Int(g.next() % UInt64(max(1, k))) }
        let breaks = ["x", "word ", "\n", "\n\n", "```\n", "- ", "> ", "# ", "    ", "`", "**", "<!--", "/*", "*/", "{", "}", "\"", "'", "${", "🙂"]
        var view = NSRange(location: 200_000, length: 30_000)
        _ = await document.runs(in: view)
        let first = await document.sliceRange
        #expect(first.map { $0.length < 150_000 } == true, "\(sample.name): the stretch \(String(describing: first))")
        var checked = 0, step = 0
        func check(_ what: String) async {
            step += 1
            await document.update(text)
            let runs = await document.runs(in: view)
            let tree = Highlighter.tree(text, language: sample.language)
            guard sample.language == .markdown || !(tree.contains("ERROR") || tree.contains("MISSING")) else { return }
            checked += 1
            let expected = Highlighter.runs(text, language: sample.language, root: sample.root, in: view)
            #expect(runs == expected, "\(sample.name) step \(step) (\(what)), view \(view): \(difference(runs, expected, in: text))")
        }
        for _ in 0..<10 {
            let length = (text as NSString).length
            if pick(4) == 0 { view.location = pick(length - 30_000) }
            let at = pick(4) == 0 ? pick(length) : view.location + pick(view.length)
            let range = NSRange(location: at, length: min(pick(5) == 0 ? pick(2_000) : pick(8), length - at))
            let insert = breaks[pick(breaks.count)], old = (text as NSString).substring(with: range)
            text = (text as NSString).replacingCharacters(in: range, with: insert)
            await check("a break")
            text = (text as NSString).replacingCharacters(in: NSRange(location: at, length: (insert as NSString).length), with: old)
            await check("undone")
        }
        #expect(checked >= 10, "\(sample.name): only \(checked) steps parsed cleanly to check")
    }

    /// A scratch file at 2.4 MB, as the harness makes it (no blank lines: its worst case for a
    /// tree, 58 bytes a character): the tree is of the stretch at the end, it colors as the
    /// whole does, typing at the end parses that stretch again and nothing else, and an edit at
    /// the top that doesn't reach the view leaves the stretch as it is.
    @Test func aScratchFileAtTwoAndAHalfMegabytes() async {
        var md = "# Scratch-sized\n", m = 0
        while md.utf8.count < 2_400_000 {
            m += 1
            md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
        }
        let document = SyntaxDocument(language: .markdown, root: "text.html.markdown")
        await document.update(md)
        var length = (md as NSString).length
        let end = NSRange(location: length - 3_000, length: 3_000)
        let runs = await document.runs(in: end)
        #expect(runs == Highlighter.runs(md, language: .markdown, root: "text.html.markdown", in: end))
        let slice = await document.sliceRange
        #expect(slice.map { $0.length < 150_000 && NSMaxRange($0) == length } == true, "the stretch: \(String(describing: slice))")
        #expect(await document.unsure.isEmpty, "every place to start is known once the whole text's been read")

        md += "## Typed at the end\n"
        length = (md as NSString).length
        #expect(await document.update(md) == .incremental(NSRange(location: length - 20, length: 20)))
        let typed = NSRange(location: length - 3_000, length: 3_000)
        #expect(await document.runs(in: typed) == Highlighter.runs(md, language: .markdown, root: "text.html.markdown", in: typed))
        #expect(await document.sliceRange.map { NSMaxRange($0) == length } == true, "the stretch grew with the text")

        let before = await document.sliceRange!
        md = (md as NSString).replacingCharacters(in: NSRange(location: 10, length: 0), with: "\n\n")
        await document.update(md)
        let moved = NSRange(location: typed.location + 2, length: typed.length)
        #expect(await document.runs(in: moved) == Highlighter.runs(md, language: .markdown, root: "text.html.markdown", in: moved))
        #expect(await document.sliceRange == NSRange(location: before.location + 2, length: before.length), "the stretch stayed, two along")
    }

    @Test func aSmallTextKeepsItsWholeTree() async {
        let document = SyntaxDocument(language: .javascript, root: "source.js")
        let text = "const a = 1;\n"
        #expect(await document.update(text) == .whole)
        #expect(await document.sliceRange == NSRange(location: 0, length: 13))
        #expect(await document.treeDescription == Highlighter.tree(text, language: .javascript))
    }
}
