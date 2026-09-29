// Highlighting (PRD HL1, HL7, §6.3): tree-sitter parses each language, and Nib's own queries
// (Queries/*.scm) name every capture with the TextMate scope Sublime gives the same text, so
// the scheme's rules (NibText's Theme) color it as Sublime does. Embedded languages (HTML's
// <script> and <style>, Markdown's inline text and fenced code) are parsed apart and nested
// inside the host's scopes, under the embedded root Sublime uses (`source.js.embedded.html`).
// A document's tree is kept across edits and styles are worked out for the stretch on screen
// (`SyntaxDocument`, §6.3); `runs` and `styles` do a whole text at once.

import Foundation
import NibText
import Synchronization
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline

public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case html, css, javascript, json, markdown, markdownInline = "markdown-inline", shell

    /// For the strip (HL1).
    public var name: String {
        switch self {
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .markdown, .markdownInline: "Markdown"
        case .shell: "Shell"
        }
    }

    /// The outermost scope, as Sublime's syntax names it (Markdown's inline layer has none of its own).
    public var rootScope: String? {
        switch self {
        case .html: "text.html.basic"
        case .css: "source.css"
        case .javascript: "source.js"
        case .json: "source.json"
        case .markdown: "text.html.markdown"
        case .markdownInline: nil
        case .shell: "source.shell.bash"
        }
    }

    var tsLanguage: Language {
        switch self {
        case .html: Language(tree_sitter_html())
        case .css: Language(tree_sitter_css())
        case .javascript: Language(tree_sitter_javascript())
        case .json: Language(tree_sitter_json())
        case .markdown: Language(tree_sitter_markdown())
        case .markdownInline: Language(tree_sitter_markdown_inline())
        case .shell: Language(tree_sitter_bash())
        }
    }

    /// Nib's query for the language, parsed once.
    var query: Query? {
        Self.queries.withLock { cache in
            if let known = cache[self] { return known }
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "scm", subdirectory: "Queries"),
                  let data = try? Data(contentsOf: url) else { return nil }
            let query = try? Query(language: tsLanguage, data: data)
            cache[self] = query
            return query
        }
    }

    private static let queries = Mutex<[SyntaxLanguage: Query?]>([:])

    /// By name, then by a shebang on the first line (HL1); nil is plain text.
    public static func detect(fileName: String, firstLine: String? = nil) -> (language: SyntaxLanguage, root: String)? {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        switch ext {
        case "html", "htm", "xhtml": return (.html, "text.html.basic")
        case "css": return (.css, "source.css")
        case "js", "mjs", "cjs": return (.javascript, "source.js")
        case "json", "jsonc", "json5": return (.json, "source.json")
        case "md", "markdown", "mdown", "mkd": return (.markdown, "text.html.markdown")
        case "zsh": return (.shell, "source.shell.zsh")
        case "sh", "bash", "command": return (.shell, "source.shell.bash")
        default: break
        }
        if [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout"].contains(name) { return (.shell, "source.shell.zsh") }
        if [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile"].contains(name) { return (.shell, "source.shell.bash") }
        if let line = firstLine, line.hasPrefix("#!") {
            if line.contains("zsh") { return (.shell, "source.shell.zsh") }
            if line.contains("bash") || line.hasSuffix("/sh") || line.contains("/sh ") || line.contains("env sh") { return (.shell, "source.shell.bash") }
        }
        return nil
    }
}

extension Theme {
    /// An Old Hope · Nib, the built-in scheme (HL10): a copy of themes/an-old-hope-nib.tmTheme,
    /// which a test keeps identical.
    public static let anOldHopeNib: Theme = {
        guard let url = Bundle.module.url(forResource: "an-old-hope-nib", withExtension: "tmTheme", subdirectory: "Themes"),
              let data = try? Data(contentsOf: url), let theme = try? Theme(tmTheme: data) else { fatalError("the built-in scheme is missing") }
        return theme
    }()
}

/// A stretch of text and its scopes, outermost first.
public struct ScopeRun: Sendable, Equatable {
    public var range: NSRange
    public var scopes: [String]
}

public enum Highlighter {
    /// The syntax tree, for writing queries (`nib-fidelity --tree`).
    public static func tree(_ text: String, language: SyntaxLanguage) -> String {
        let parser = Parser()
        guard (try? parser.setLanguage(language.tsLanguage)) != nil, let tree = parser.parse(text) else { return "" }
        return tree.rootNode?.sExpressionString ?? ""
    }

    /// Every character's scopes, as runs covering the whole text (or only `window` of it).
    public static func runs(_ text: String, language: SyntaxLanguage, root: String? = nil, in window: NSRange? = nil) -> [ScopeRun] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        let window = window.map { NSIntersectionRange($0, whole) } ?? whole
        var spans: [Span] = []
        collect(source, whole, language, roots: [root ?? language.rootScope].compactMap { $0 }, window: window, string: text, into: &spans)
        return sweep(spans, window: window)
    }

    /// Each run's style from the scheme.
    public static func styles(_ text: String, language: SyntaxLanguage, root: String? = nil, theme: Theme) -> [(range: NSRange, style: Style)] {
        var cache = StyleCache(theme: theme)
        return runs(text, language: language, root: root).map { ($0.range, cache.style(for: $0.scopes)) }
    }

    /// A scope stack's style, worked out once: a file has a few hundred distinct stacks among
    /// a million runs (5 MB of JavaScript: 12.7 s resolving each run, 0.15 s each stack once).
    struct StyleCache {
        let theme: Theme
        var known: [[String]: Style] = [:]

        init(theme: Theme) { self.theme = theme }

        mutating func style(for scopes: [String]) -> Style {
            if let style = known[scopes] { return style }
            let style = theme.style(for: scopes)
            known[scopes] = style
            return style
        }
    }

    struct Span {
        var range: NSRange
        var scope: String
        /// Where it covers the same text as another, the higher is inner: embedded languages
        /// inside their host, a later pattern inside an earlier one, then the order found.
        var order: (level: Int, pattern: Int, seq: Int)
    }

    /// The language's captures within `range` that touch `window`, then its embedded languages
    /// there, recursively. A tree already parsed for `range` (a `SyntaxDocument`'s) is used as
    /// is; embedded languages are parsed on the spot (a paragraph, a fence, a script).
    static func collect(_ text: NSString, _ range: NSRange, _ language: SyntaxLanguage, roots: [String], level: Int = 0,
                        window: NSRange, tree given: MutableTree? = nil, string: String? = nil, into spans: inout [Span]) {
        guard intersects(range, window) || (range.length == 0 && window.length == 0) else { return }
        for (i, root) in roots.enumerated() { spans.append(Span(range: range, scope: root, order: (level, -roots.count + i, spans.count))) }
        let part = string ?? text.substring(with: range)
        var parsed = given
        if parsed == nil {
            let parser = Parser()
            guard (try? parser.setLanguage(language.tsLanguage)) != nil else { return }
            parsed = parser.parse(part)
        }
        guard let tree = parsed, let root = tree.rootNode else { return }
        // The window in this part's own terms.
        let local = NSRange(location: max(0, window.location - range.location),
                            length: max(0, min(NSMaxRange(window), NSMaxRange(range)) - max(window.location, range.location)))
        if let query = language.query {
            var captured: [(span: Span, only: Bool)] = [], marks: [Span] = []
            let cursor = query.execute(in: tree)
            cursor.setRange(local)
            for match in cursor.resolve(with: .init(string: part)) {
                for capture in match.captures {
                    guard var name = capture.name, !name.hasPrefix("_"), capture.range.length > 0 else { continue }
                    let whole = NSRange(location: capture.range.location + range.location, length: capture.range.length)
                    // `only.<scope>`: this text takes that scope and none of the others captured on it.
                    // `clear.<scope>`: inside it, the strings around it no longer apply (as
                    // Sublime's clear_scopes does for $(…) and ${…} in a shell string).
                    let only = name.hasPrefix("only.")
                    if only { name.removeFirst(5) }
                    if name.hasPrefix("clear.") { name.removeFirst(6); name = "\u{1}" + name }
                    captured.append((Span(range: whole, scope: name, order: (level, match.patternIndex, spans.count + captured.count)), only))
                    for (inner, scope) in delimiters(of: name, in: text.substring(with: whole)) {
                        marks.append(Span(range: NSRange(location: whole.location + inner.location, length: inner.length), scope: scope,
                                          order: (level, Int.max, spans.count + captured.count + marks.count)))
                    }
                }
            }
            let onlyRanges = Set(captured.filter(\.only).map { NSStringFromRange($0.span.range) })
            spans += captured.filter { $0.only || !onlyRanges.contains(NSStringFromRange($0.span.range)) }.map(\.span)
            spans += marks
        }
        for injection in Injections.find(in: root, text: part as NSString, language: language, window: local) {
            let inner = NSRange(location: injection.range.location + range.location, length: injection.range.length)
            collect(text, inner, injection.language, roots: injection.scopes, level: level + 1, window: window, into: &spans)
        }
    }

    /// Two ranges share at least one character.
    static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location < NSMaxRange(b) && b.location < NSMaxRange(a)
    }

    /// A `clear.` scope (marked with \u{1}) drops the string scopes outside it; the mark goes.
    static func cleared(_ stack: [String]) -> [String] {
        guard let at = stack.lastIndex(where: { $0.hasPrefix("\u{1}") }) else { return stack }
        var out = stack
        out[at].removeFirst()
        let outer = out[..<at].filter { !$0.hasPrefix("string.") && !$0.hasPrefix("meta.string") }
        return cleared(Array(outer) + out[at...])
    }

    /// Characters tree-sitter keeps inside one token that Sublime scopes apart: quotes, comment
    /// markers, the `@` of an at-rule, the `!` of `!important`, an entity's `&` and `;`, a
    /// shell variable's `$` (all `punctuation.definition.*`, which An Old Hope draws plain);
    /// a number's decimal point and sign; DOCTYPE's words; a URL's separators; an entity in an
    /// attribute value; a documentation comment's `@param`.
    static func delimiters(of scope: String, in token: String) -> [(NSRange, String)] {
        let t = token as NSString, n = t.length
        var out: [(NSRange, String)] = []
        func mark(_ at: Int, _ length: Int, _ kind: String) { if length > 0, at >= 0, at + length <= n { out.append((NSRange(location: at, length: length), kind)) } }
        func each(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            (try? NSRegularExpression(pattern: pattern))?.matches(in: token, range: NSRange(location: 0, length: n)).forEach(body)
        }
        /// "https://example.com/q4?x": the scheme's colon, every slash, the question mark.
        func urlSeparators(_ kind: String) {
            guard token.contains("://") || token.hasPrefix("/") else { return }
            each(#"://|/|\?"#) { mark($0.range.location, $0.range.length, kind) }
        }
        if scope.hasPrefix("string.quoted.") {
            if scope.hasSuffix(".shell") { each(#"\\."#) { mark($0.range.location, 2, "constant.character.escape.shell") } }
            let quotes: Set<unichar> = [0x22, 0x27, 0x60]   // " ' `
            if n > 0, quotes.contains(t.character(at: 0)) { mark(0, 1, "punctuation.definition.string.begin") }
            if n > 1, quotes.contains(t.character(at: n - 1)) { mark(n - 1, 1, "punctuation.definition.string.end") }
            if scope.hasSuffix(".html") {
                urlSeparators("punctuation.separator.path.html")
                each("&[A-Za-z0-9#]+;") { m in
                    mark(m.range.location, m.range.length, "constant.character.entity.named.html")
                    mark(m.range.location, 1, "punctuation.definition.entity.html")
                    mark(NSMaxRange(m.range) - 1, 1, "punctuation.definition.entity.html")
                }
            }
        } else if scope.hasPrefix("markup.underline.link") {
            urlSeparators("punctuation.separator.path.markdown")
        } else if scope.hasPrefix("string.regexp") {
            // /\s+/g: the slashes are the string's own marks, the quantifiers operators.
            if token.hasPrefix("/") { mark(0, 1, "punctuation.definition.string.begin") }
            each(#"(?<!\\)[+*?]"#) { mark($0.range.location, 1, "keyword.operator.quantifier.regexp") }
            each(#"\\[sSdDwWbB]"#) { mark($0.range.location, 2, "constant.other.character-class.escape.backslash.regexp") }
            if let close = token.lastIndex(of: "/"), token.distance(from: token.startIndex, to: close) > 0 {
                mark(token.utf16.distance(from: token.utf16.startIndex, to: close.samePosition(in: token.utf16) ?? token.utf16.startIndex), 1, "punctuation.definition.string.end")
            }
        } else if scope.hasPrefix("string.unquoted.shell") {
            if token.hasPrefix("~") { mark(0, 1, "variable.language.tilde.shell") }
            each(":(?=~)") { mark($0.range.location, 1, "punctuation.separator.sequence.shell") }
            each(#"(?<!\\)[*?]"#) { mark($0.range.location, 1, "constant.other.wildcard.asterisk.shell") }
        } else if scope.hasPrefix("meta.interpolation") && scope.hasSuffix(".shell"), token.hasPrefix("$") {
            mark(0, 1, "punctuation.definition.variable.shell")
        } else if scope.hasPrefix("support.constant.property-value.css"),
                  token.range(of: #"^([0-9.]|[a-z%]*/[0-9.])"#, options: .regularExpression) != nil {
            // 15px/1.5 (which tree-sitter reads as 15 and px/1.5): numbers, units, the slash.
            if let unit = token.range(of: #"^[a-z%]+(?=/)"#, options: .regularExpression) {
                mark(0, token.distance(from: unit.lowerBound, to: unit.upperBound), "constant.numeric.suffix.css")
            }
            each(#"(\d*\.?\d+)([a-z%]*)"#) { m in
                mark(m.range(at: 1).location, m.range(at: 1).length, "constant.numeric.value.css")
                mark(m.range(at: 2).location, m.range(at: 2).length, "constant.numeric.suffix.css")
            }
            each(#"\."#) { mark($0.range.location, 1, "punctuation.separator.decimal.css") }
            each("/") { mark($0.range.location, 1, "keyword.operator.arithmetic.css") }
        } else if scope.hasPrefix("meta.property.object") || scope.hasPrefix("variable.other.readwrite.js") || scope.hasPrefix("entity.name.function.js"), token.hasPrefix("#") {
            mark(0, 1, "punctuation.definition.variable")
        } else if scope.hasPrefix("constant.numeric") {
            each(#"\."#) { mark($0.range.location, 1, "punctuation.separator.decimal") }
            if token.hasPrefix("-") || token.hasPrefix("+") { mark(0, 1, "keyword.operator.arithmetic") }
        } else if scope.hasPrefix("meta.tag.sgml.doctype") {
            each("(?i)(doctype)\\s+(\\w+)") { m in
                mark(m.range(at: 1).location, m.range(at: 1).length, "keyword.declaration.doctype.html")
                mark(m.range(at: 2).location, m.range(at: 2).length, "constant.language.doctype.html")
            }
        } else if scope.hasPrefix("comment.") {
            if scope.hasPrefix("comment.block.documentation") {
                each(#"@[A-Za-z]+"#) { mark($0.range.location, $0.range.length, "entity.other.attribute-name.documentation") }
            }
            if token.hasPrefix("/*") {
                mark(0, token.hasPrefix("/**") && !token.hasPrefix("/**/") ? 3 : 2, "punctuation.definition.comment.begin")
                if n > 3, token.hasSuffix("*/") { mark(n - 2, 2, "punctuation.definition.comment.end") }
                // The * that starts each line inside it.
                each(#"(?m)^[ \t]*(\*)(?!/)"#) { m in if m.range(at: 1).location > 0 { mark(m.range(at: 1).location, 1, "punctuation.definition.comment") } }
            }
            else if scope.hasPrefix("comment.line.shebang") {
                mark(0, 2, "punctuation.definition.comment")
                each(#"[A-Za-z0-9_.+-]+\s*$"#) { mark($0.range.location, $0.range.length, "constant.language.shebang") }
            }
            else if token.hasPrefix("//") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix("<!--") { mark(0, 4, "punctuation.definition.comment.begin"); if n > 6, token.hasSuffix("-->") { mark(n - 3, 3, "punctuation.definition.comment.end") } }
            else if token.hasPrefix("#!") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix("#") { mark(0, 1, "punctuation.definition.comment") }
        } else if scope.hasPrefix("keyword.control.at-rule"), token.hasPrefix("@") {
            mark(0, 1, "punctuation.definition.keyword")
        } else if scope.hasPrefix("constant.character.entity"), token.hasPrefix("&") {
            mark(0, 1, "punctuation.definition.entity")
            if token.hasSuffix(";") { mark(n - 1, 1, "punctuation.definition.entity") }
        } else if scope.hasPrefix("variable"), token.hasPrefix("$") {
            mark(0, token.hasPrefix("${") ? 2 : 1, "punctuation.definition.variable")
        }
        return out
    }

    /// Spans into runs across `window`: at each boundary, the spans covering the stretch, outer
    /// (longer, measured whole, not cut to the window) first, and in the order they were found
    /// where they cover the same text.
    static func sweep(_ spans: [Span], window: NSRange) -> [ScopeRun] {
        let start = window.location, end = NSMaxRange(window)
        var cuts = Set([start, end])
        for span in spans {
            for cut in [span.range.location, NSMaxRange(span.range)] where cut > start && cut < end { cuts.insert(cut) }
        }
        let bounds = cuts.sorted()
        let byStart = spans.sorted { $0.range.location < $1.range.location }
        var runs: [ScopeRun] = [], active: [Span] = [], next = 0
        for (a, b) in zip(bounds, bounds.dropFirst()) where b > a {
            active.removeAll { NSMaxRange($0.range) <= a }
            while next < byStart.count, byStart[next].range.location <= a {
                if NSMaxRange(byStart[next].range) > a { active.append(byStart[next]) }
                next += 1
            }
            let sorted = active.sorted {
                if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
                return ($0.order.level, $0.order.pattern, $0.order.seq) < ($1.order.level, $1.order.pattern, $1.order.seq)
            }.map(\.scope)
            let stack = cleared(sorted)
            if let last = runs.last, last.scopes == stack, NSMaxRange(last.range) == a {
                runs[runs.count - 1].range.length += b - a
            } else {
                runs.append(ScopeRun(range: NSRange(location: a, length: b - a), scopes: stack))
            }
        }
        return runs
    }
}

/// Where one language holds another (HL1): found by walking the tree, since each needs its
/// own scopes around it, as Sublime's syntaxes nest them.
enum Injections {
    struct Injection {
        var range: NSRange
        var language: SyntaxLanguage
        var scopes: [String]
    }

    /// The embedded languages that touch `window` (a whole text when it's all of it).
    static func find(in root: Node, text: NSString, language: SyntaxLanguage, window: NSRange? = nil) -> [Injection] {
        var found: [Injection] = []
        func walk(_ node: Node) {
            if let window, !Highlighter.intersects(node.range, window) { return }   // nothing of it on screen
            switch (language, node.nodeType) {
            case (.html, "script_element"?), (.html, "style_element"?):
                let script = node.nodeType == "script_element"
                if let raw = child(of: node, type: "raw_text") {
                    found.append(Injection(range: raw.range, language: script ? .javascript : .css,
                                           scopes: [script ? "source.js.embedded.html" : "source.css.embedded.html"]))
                }
                return
            case (.markdown, "inline"?):
                found.append(Injection(range: node.range, language: .markdownInline, scopes: []))
                return
            case (.markdown, "fenced_code_block"?):
                let info = child(of: node, type: "info_string").flatMap { child(of: $0, type: "language") }
                let name = info.map { text.substring(with: $0.range).lowercased() } ?? ""
                if let content = child(of: node, type: "code_fence_content"), let (fenced, scopes) = fence(name) {
                    found.append(Injection(range: content.range, language: fenced, scopes: scopes))
                }
                return
            default:
                break
            }
            node.enumerateChildren { walk($0) }
        }
        walk(root)
        return found
    }

    static func child(of node: Node, type: String) -> Node? {
        var result: Node?
        node.enumerateChildren { if result == nil, $0.nodeType == type { result = $0 } }
        return result
    }

    /// A fenced block's language, and the scopes Sublime puts around its code.
    static func fence(_ name: String) -> (SyntaxLanguage, [String])? {
        let table: [String: (SyntaxLanguage, String, String)] = [
            "bash": (.shell, "shell", "source.shell.bash"), "sh": (.shell, "shell", "source.shell.bash"),
            "shell": (.shell, "shell", "source.shell.bash"), "zsh": (.shell, "shell", "source.shell.zsh"),
            "js": (.javascript, "javascript", "source.js"), "javascript": (.javascript, "javascript", "source.js"),
            "json": (.json, "json", "source.json"), "css": (.css, "css", "source.css"), "html": (.html, "html", "text.html.basic"),
        ]
        guard let (language, id, root) = table[name] else { return nil }
        return (language, ["markup.raw.code-fence.\(id).markdown-gfm", root])
    }
}
