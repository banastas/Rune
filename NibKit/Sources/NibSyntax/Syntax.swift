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
import TreeSitterXML
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterPython
import TreeSitterYAML
import TreeSitterTOML
import TreeSitterMake
import TreeSitterDiff
import TreeSitterGitCommit
import TreeSitterGitIgnore
import TreeSitterGitAttributes
import TreeSitterGitConfig
import TreeSitterINI
import TreeSitterGo
import TreeSitterRust
import TreeSitterRuby
import TreeSitterJava
import TreeSitterC
import TreeSitterLua
import TreeSitterPHP
import TreeSitterSQL
import TreeSitterRST
import TreeSitterSwift

public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case html, css, javascript, json, markdown, markdownInline = "markdown-inline", shell, xml
    // HL8's list (2026-10-02).
    case jsx, typescript, tsx, diff, gitCommit = "git-commit", gitIgnore = "git-ignore", gitAttributes = "git-attributes",
         gitConfig = "git-config", makefile, yaml, toml, python, ini
    // Its second tier.
    case go, rust, ruby, java, c, lua, php, sql, rst
    // Swift, whose colors are Nib's own (Sublime has no Swift).
    case swift

    /// For the strip (HL1).
    public var name: String {
        switch self {
        case .html: "HTML"
        case .css: "CSS"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .markdown, .markdownInline: "Markdown"
        case .shell: "Shell"
        case .xml: "XML"
        case .jsx: "JSX"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .diff: "Diff"
        case .gitCommit: "Git Commit"
        case .gitIgnore: "Git Ignore"
        case .gitAttributes: "Git Attributes"
        case .gitConfig: "Git Config"
        case .makefile: "Makefile"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .python: "Python"
        case .ini: "INI"
        case .go: "Go"
        case .rust: "Rust"
        case .ruby: "Ruby"
        case .java: "Java"
        case .c: "C"
        case .lua: "Lua"
        case .php: "PHP"
        case .sql: "SQL"
        case .rst: "reStructuredText"
        case .swift: "Swift"
        }
    }

    /// The outermost scope, as Sublime's syntax names it (Markdown's inline layer has none of its
    /// own; INI, which Sublime doesn't color, takes the name Sublime's INI packages give it).
    public var rootScope: String? {
        switch self {
        case .html: "text.html.basic"
        case .css: "source.css"
        case .javascript: "source.js"
        case .json: "source.json"
        case .markdown: "text.html.markdown"
        case .markdownInline: nil
        case .shell: "source.shell.bash"
        case .xml: "text.xml"
        case .jsx: "source.jsx"
        case .typescript: "source.ts"
        case .tsx: "source.tsx"
        case .diff: "source.diff"
        case .gitCommit: "text.git.commit"
        case .gitIgnore: "text.git.ignore"
        case .gitAttributes: "text.git.attributes"
        case .gitConfig: "text.git.config"
        case .makefile: "source.makefile"
        case .yaml: "source.yaml"
        case .toml: "source.toml"
        case .python: "source.python"
        case .ini: "source.ini"
        case .go: "source.go"
        case .rust: "source.rust"
        case .ruby: "source.ruby"
        case .java: "source.java"
        case .c: "source.c"
        case .lua: "source.lua"
        case .php: "embedding.php"
        case .sql: "source.sql"
        case .rst: "text.restructuredtext"
        case .swift: "source.swift"
        }
    }

    var tsLanguage: Language {
        switch self {
        case .html: Language(tree_sitter_html())
        case .css: Language(tree_sitter_css())
        case .javascript, .jsx: Language(tree_sitter_javascript())
        case .json: Language(tree_sitter_json())
        case .markdown: Language(tree_sitter_markdown())
        case .markdownInline: Language(tree_sitter_markdown_inline())
        case .shell: Language(tree_sitter_bash())
        case .xml: Language(tree_sitter_xml())
        case .typescript: Language(tree_sitter_typescript())
        case .tsx: Language(tree_sitter_tsx())
        case .diff: Language(tree_sitter_diff())
        case .gitCommit: Language(tree_sitter_gitcommit())
        case .gitIgnore: Language(tree_sitter_gitignore())
        case .gitAttributes: Language(tree_sitter_gitattributes())
        case .gitConfig: Language(tree_sitter_git_config())
        case .makefile: Language(tree_sitter_make())
        case .yaml: Language(tree_sitter_yaml())
        case .toml: Language(tree_sitter_toml())
        case .python: Language(tree_sitter_python())
        case .ini: Language(tree_sitter_ini())
        case .go: Language(tree_sitter_go())
        case .rust: Language(tree_sitter_rust())
        case .ruby: Language(tree_sitter_ruby())
        case .java: Language(tree_sitter_java())
        case .c: Language(tree_sitter_c())
        case .lua: Language(tree_sitter_lua())
        case .php: Language(tree_sitter_php())
        case .sql: Language(tree_sitter_sql())
        case .rst: Language(tree_sitter_rst())
        case .swift: Language(tree_sitter_swift())
        }
    }

    /// The query files a language's query is made of, in order (a later pattern wins where two
    /// capture the same text). JavaScript's grammar reads JSX, in a .js file too, and so does
    /// TSX's; TypeScript's grammar names some of JavaScript's nodes differently
    /// (`public_field_definition`, `type_identifier`), so it has its own.
    var queryFiles: [String] {
        switch self {
        case .javascript, .jsx: ["javascript", "jsx"]
        case .typescript: ["typescript"]
        case .tsx: ["typescript", "jsx"]
        default: [rawValue]
        }
    }

    /// Nib's query for the language, parsed once.
    var query: Query? {
        Self.queries.withLock { cache in
            if let known = cache[self] { return known }
            var data = Data()
            for file in queryFiles {
                guard let url = Bundle.module.url(forResource: file, withExtension: "scm", subdirectory: "Queries"),
                      let part = try? Data(contentsOf: url) else { return nil }
                data += part + Data("\n".utf8)
            }
            let query = try? Query(language: tsLanguage, data: data)
            cache[self] = query
            return query
        }
    }

    private static let queries = Mutex<[SyntaxLanguage: Query?]>([:])

    /// Why the query doesn't compile (a node type or field the grammar doesn't have, a bad
    /// predicate), or nil when it does: for writing queries (`nib-fidelity --queries`).
    public var queryProblem: String? {
        var data = Data()
        for file in queryFiles {
            guard let url = Bundle.module.url(forResource: file, withExtension: "scm", subdirectory: "Queries"),
                  let part = try? Data(contentsOf: url) else { return "\(file).scm is missing" }
            data += part + Data("\n".utf8)
        }
        do { _ = try Query(language: tsLanguage, data: data); return nil } catch { return "\(error)" }
    }

    /// By name, then by the first line: a shebang (HL1), or what Sublime's syntaxes look for there
    /// (XML's declaration, a DOCTYPE that isn't HTML's, `%YAML`, a .git/config's `[core]`, a
    /// diff's header); nil is plain text. Names and extensions as Sublime's syntaxes list them
    /// (HL8), with `.env` read as shell and INI's, which Sublime doesn't color, Nib's own.
    public static func detect(fileName: String, firstLine: String? = nil) -> (language: SyntaxLanguage, root: String)? {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        switch name {
        case ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout": return (.shell, "source.shell.zsh")
        case ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".profile", ".bash_aliases": return (.shell, "source.shell.bash")
        case "makefile", "gnumakefile", "makefile.am", "makefile.in", "ocamlmakefile": return (.makefile, "source.makefile")
        case "commit_editmsg", "merge_msg", "tag_editmsg": return (.gitCommit, "text.git.commit")
        case ".gitignore": return (.gitIgnore, "text.git.ignore")
        case ".gitattributes": return (.gitAttributes, "text.git.attributes")
        case ".gitconfig", ".gitmodules": return (.gitConfig, "text.git.config")
        case "pipfile", "cargo.lock", "gopkg.lock", "mise.lock", "pdm.lock", "poetry.lock", "uv.lock": return (.toml, "source.toml")
        case "citation.cff": return (.yaml, "source.yaml")
        case "sconstruct", "sconscript", "snakefile": return (.python, "source.python")
        case "pipfile.lock", "sublime_session": return (.json, "source.json")
        case ".editorconfig": return (.ini, "source.ini")
        case ".env": return (.shell, "source.shell.bash")
        case "appfile", "appraisals", "berksfile", "brewfile", "cheffile", "deliverfile", "fastfile", "gemfile", "guardfile",
             "podfile", "rakefile", "rantfile", "scanfile", "snapfile", "thorfile", "vagrantfile", "capfile", ".irbrc", ".pryrc", ".simplecov":
            return (.ruby, "source.ruby")
        default: break
        }
        if name.hasPrefix(".env.") { return (.shell, "source.shell.bash") }   // .env.local, .env.production
        switch ext {
        case "html", "htm", "xhtml": return (.html, "text.html.basic")
        case "css": return (.css, "source.css")
        case "js", "mjs", "cjs": return (.javascript, "source.js")
        case "json", "jsonc", "json5",
             // Sublime's own settings files, notebooks and the rest of what Sublime reads as JSON.
             "sublime-build", "sublime-color-scheme", "sublime-commands", "sublime-completions", "sublime-file-icons",
             "sublime-keymap", "sublime-macro", "sublime-menu", "sublime-mousemap", "sublime-project", "sublime-settings",
             "sublime-theme", "sublime-merge-theme", "sublime-workspace", "hidden-color-scheme", "ipynb", "gltf", "avsc":
            return (.json, "source.json")
        case "md", "markdown", "mdown", "mkd": return (.markdown, "text.html.markdown")
        case "zsh": return (.shell, "source.shell.zsh")
        case "sh", "bash", "command", "ash", "bashrc", "env": return (.shell, "source.shell.bash")
        // Sublime's XML extensions, and the ones it doesn't list in its menus (tmTheme, csproj…).
        case "xml", "tld", "dtml", "rng", "rss", "opml", "slnx", "svg", "xaml",
             "sublime-snippet", "tmlanguage", "hidden-tmlanguage", "tmpreferences", "tmsnippet", "tmtheme", "hidden-tmtheme",
             "csproj", "fsproj", "sqlproj", "vbproj", "vcproj", "vcxproj", "dae", "props", "drawio", "targets":
            return (.xml, "text.xml")
        case "jsx": return (.jsx, "source.jsx")
        case "ts", "mts", "cts": return (.typescript, "source.ts")
        case "tsx": return (.tsx, "source.tsx")
        case "diff", "patch": return (.diff, "source.diff")
        case "gitignore": return (.gitIgnore, "text.git.ignore")
        case "gitattributes": return (.gitAttributes, "text.git.attributes")
        case "gitconfig": return (.gitConfig, "text.git.config")
        case "mk", "mak", "make": return (.makefile, "source.makefile")
        case "yaml", "yml", "sublime-syntax": return (.yaml, "source.yaml")
        case "toml", "tml": return (.toml, "source.toml")
        case "py", "py3", "pyw", "pyi", "pyx", "pxd", "pxi", "rpy", "cpy", "gyp", "gypi", "vpy", "smk", "wscript", "bazel", "bzl":
            return (.python, "source.python")
        case "ini", "cfg": return (.ini, "source.ini")
        case "go": return (.go, "source.go")
        case "rs": return (.rust, "source.rust")
        case "rb", "rbi", "rbx", "rjs", "rabl", "rake", "capfile", "jbuilder", "gemspec", "podspec", "irbrc", "pryrc", "prawn", "thor":
            return (.ruby, "source.ruby")
        case "java", "bsh": return (.java, "source.java")
        case "c", "h": return (.c, "source.c")
        case "lua": return (.lua, "source.lua")
        case "php", "php3", "php4", "php5", "php7", "php8", "phps", "phpt", "phtml": return (.php, "embedding.php")
        case "sql", "ddl", "dml": return (.sql, "source.sql")
        case "rst", "rest": return (.rst, "text.restructuredtext")
        case "swift", "swiftinterface": return (.swift, "source.swift")
        default: break
        }
        guard let line = firstLine else { return nil }
        if line.hasPrefix("#!") {
            if line.contains("zsh") { return (.shell, "source.shell.zsh") }
            if line.contains("bash") || line.hasSuffix("/sh") || line.contains("/sh ") || line.contains("env sh") { return (.shell, "source.shell.bash") }
            if line.range(of: #"\b(?:python(?:\d(?:\.\d+)?)?|uv)\b"#, options: .regularExpression) != nil { return (.python, "source.python") }
            if line.range(of: #"\bts-node(?:-script)?\b"#, options: .regularExpression) != nil { return (.typescript, "source.ts") }
            if line.range(of: #"\b(?:node|js|bun)\b"#, options: .regularExpression) != nil { return (.javascript, "source.js") }
            if line.range(of: #"\bmake\b"#, options: .regularExpression) != nil { return (.makefile, "source.makefile") }
            if line.range(of: #"\bj?ruby\b"#, options: .regularExpression) != nil { return (.ruby, "source.ruby") }
            if line.range(of: #"\b(?:cargo|rust)\b"#, options: .regularExpression) != nil { return (.rust, "source.rust") }
            if line.range(of: #"\b(?:bsh|java)\b"#, options: .regularExpression) != nil { return (.java, "source.java") }
            if line.range(of: #"\blua\b"#, options: .regularExpression) != nil { return (.lua, "source.lua") }
            if line.range(of: #"\bswift\b"#, options: .regularExpression) != nil { return (.swift, "source.swift") }
            if line.range(of: #"[^-]\bphp(?:\d+(?:\.\d+){0,2})?\b"#, options: .regularExpression) != nil { return (.php, "embedding.php") }
        }
        if line.range(of: #"^\s*<\?php\b"#, options: .regularExpression) != nil { return (.php, "embedding.php") }
        if line.range(of: xmlFirstLine, options: .regularExpression) != nil { return (.xml, "text.xml") }
        if line.hasPrefix("%YAML") { return (.yaml, "source.yaml") }
        if line.hasPrefix("[core]") { return (.gitConfig, "text.git.config") }   // a repository's .git/config
        if line.range(of: diffFirstLine, options: .regularExpression) != nil { return (.diff, "source.diff") }
        return nil
    }

    /// Sublime's first_line_match for XML: a declaration (`<?xml version…`), a SOAP envelope,
    /// or a DOCTYPE other than HTML's (a plist's). The line comes without its line break, so
    /// the line's end stands in for it (and a CRLF file's line ends with its \r).
    static let xmlFirstLine = #"^(?:<\?xml(?:\s|$)|\s*<([\w-]+):Envelope\s+xmlns:\1\s*=\s*"http://schemas\.xmlsoap\.org/soap/envelope/"\s*>|\s*(?i:<!DOCTYPE\s+(?!html(?:[ \t\r\f>]|$))))"#

    /// Sublime's first_line_match for a diff: the header of one in any of the forms it knows.
    static let diffFirstLine = #"^(?:=== modified file|====\s*//.+\s-\s.+\s+====|Index: |Prereq: |--- [^%]|\*\*\*.*\d{4}\s*$|\d+(,\d+)*[adc]\d+(,\d+)*$)"#
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

    /// Every node, the unnamed ones too (a quote, a keyword, what an ERROR holds), one a line
    /// with its text, for writing queries (`nib-fidelity --nodes`).
    public static func nodes(_ text: String, language: SyntaxLanguage) -> String {
        let parser = Parser()
        guard (try? parser.setLanguage(language.tsLanguage)) != nil, let tree = parser.parse(text), let root = tree.rootNode else { return "" }
        let source = text as NSString
        var lines: [String] = []
        func walk(_ node: Node, _ depth: Int) {
            let type = node.nodeType ?? "?"
            let leaf = node.childCount == 0
            let part = leaf ? " “" + source.substring(with: node.range).replacingOccurrences(of: "\n", with: "⏎") + "”" : ""
            lines.append(String(repeating: "  ", count: depth) + (node.isNamed ? type : "'\(type)'") + (node.isMissing ? " MISSING" : "") + part)
            node.enumerateChildren { walk($0, depth + 1) }
        }
        walk(root, 0)
        return lines.joined(separator: "\n")
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
    /// is, with `string` the text it was parsed from (a stretch's runs on past `range` by its
    /// closer, and a capture's text comes from it); embedded languages are parsed on the spot (a
    /// paragraph, a fence, a script).
    static func collect(_ text: NSString, _ range: NSRange, _ language: SyntaxLanguage, roots: [String], level: Int = 0,
                        window: NSRange, tree given: MutableTree? = nil, string: String? = nil, into spans: inout [Span]) {
        guard intersects(range, window) || (range.length == 0 && window.length == 0) else { return }
        for (i, root) in roots.enumerated() { spans.append(Span(range: range, scope: root, order: (level, -roots.count + i, spans.count))) }
        let part = string ?? text.substring(with: range), source = part as NSString
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
                    for (inner, scope) in delimiters(of: name, in: source.substring(with: capture.range)) {
                        marks.append(Span(range: NSRange(location: whole.location + inner.location, length: inner.length), scope: scope,
                                          order: (level, Int.max, spans.count + captured.count + marks.count)))
                    }
                }
            }
            let onlyRanges = Set(captured.filter(\.only).map { NSStringFromRange($0.span.range) })
            spans += captured.filter { $0.only || !onlyRanges.contains(NSStringFromRange($0.span.range)) }.map(\.span)
            spans += marks
        }
        for injection in Injections.find(in: root, text: source, language: language, window: local) {
            // One a stretch's end cuts off (it runs on into the closer): up to that end, read with
            // its own language's closer, as the stretch is (a fence's /* … */ in JavaScript).
            var part = injection.range, closer = ""
            if NSMaxRange(part) > range.length {
                part.length = max(0, range.length - part.location)
                closer = String(decoding: injection.language.closer, as: UTF16.self)
            }
            let inner = NSRange(location: part.location + range.location, length: part.length)
            // Its holes (make's references in a recipe) blanked, the same length, for its parser.
            var piece = source.substring(with: part)
            if !injection.holes.isEmpty {
                let blanked = NSMutableString(string: piece)
                for hole in injection.holes {
                    let cut = NSIntersectionRange(hole, part)
                    guard cut.length > 0 else { continue }
                    blanked.replaceCharacters(in: NSRange(location: cut.location - part.location, length: cut.length),
                                              with: String(repeating: "_", count: cut.length))
                }
                piece = blanked as String
            }
            collect(text, inner, injection.language, roots: injection.scopes, level: level + 1, window: window,
                    string: piece + closer, into: &spans)
            // The holes are the host's, under the scopes it gives them (PHP's code in a page's HTML:
            // embedded, the HTML's strings round it cleared).
            for hole in injection.holes where !injection.holeScopes.isEmpty {
                let absolute = NSRange(location: hole.location + range.location, length: hole.length)
                for (i, scope) in injection.holeScopes.enumerated() {
                    let name = scope.hasPrefix("clear.") ? "\u{1}" + scope.dropFirst(6) : scope
                    spans.append(Span(range: absolute, scope: name, order: (level + 1, Int.max - 1, spans.count + i)))
                }
            }
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
    /// markers, the `@` of an at-rule, the `!` of `!important`, an entity's `&` (`&#`, `&#x`)
    /// and `;`, a shell variable's `$` (all `punctuation.definition.*`, which An Old Hope draws
    /// plain); a number's decimal point and sign; DOCTYPE's words; a URL's separators; an entity
    /// in an attribute value; a documentation comment's `@param`; an XML name's namespace and
    /// its colon (`itunes:image`).
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
        if scope.hasPrefix("string.quoted."), scope.hasSuffix(".python") {
            // f"…", r'…', b"""…""": the prefix a storage type, then the quotes, three or one.
            let prefix = token.prefix { "rRbBuUfF".contains($0) }.count
            let body = token.dropFirst(prefix)
            let quote = body.hasPrefix("\"\"\"") || body.hasPrefix("'''") ? 3 : body.hasPrefix("\"") || body.hasPrefix("'") ? 1 : 0
            if prefix > 0 { mark(0, prefix, "storage.type.string.python") }
            if quote > 0 {
                mark(prefix, quote, "punctuation.definition.string.begin.python")
                // The closing quotes, if it has them yet (not while it's being typed).
                if n >= prefix + 2 * quote, token.hasSuffix(String(body.prefix(quote))) {
                    mark(n - quote, quote, "punctuation.definition.string.end.python")
                }
            }
            // %-formatting's placeholders (not in a raw string, which is a regular expression).
            if !token.hasPrefix("r"), !token.hasPrefix("br") {
                each(#"%[-#0 +]*(?:\*|\d+)?(?:\.(?:\*|\d+))?[diouxXeEfFgGcrsa]"#) { mark($0.range.location, $0.range.length, "constant.other.placeholder.python") }
            }
        } else if scope.hasPrefix("string.quoted.") {
            if scope.hasSuffix(".shell") { each(#"\\."#) { mark($0.range.location, 2, "constant.character.escape.shell") } }
            if scope == "string.quoted.single.java", n > 2 { mark(1, n - 2, "constant.character.literal.java") }   // ':'
            if scope.hasPrefix("string.quoted.other.lt-gt"), n > 1 {   // #include <stdio.h>
                mark(0, 1, "punctuation.definition.string.begin"); mark(n - 1, 1, "punctuation.definition.string.end")
            }
            if scope == "string.quoted.double.c" {   // printf's conversions: "%zu", "%-8.2f"
                each(#"%[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|j|z|t|L)?[diouxXeEfFgGaAcspn]"#) { mark($0.range.location, $0.range.length, "constant.other.placeholder.c") }
            }
            if scope.hasSuffix(".go") {   // fmt's verbs: "%w", "%-8.2f"
                each(#"%[-+# 0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?[vTtbcdoOqxXUeEfFgGspw]"#) { mark($0.range.location, $0.range.length, "constant.other.placeholder.go") }
            }
            let quotes: Set<unichar> = [0x22, 0x27, 0x60]   // " ' `
            if n == 1, quotes.contains(t.character(at: 0)) { mark(0, 1, "punctuation.definition.string") }   // a quote on its own (XML's declaration)
            // Three quotes are the marks of a block string (TOML's, Python's docstrings).
            let triple = n >= 6 && (token.hasPrefix("\"\"\"") || token.hasPrefix("'''")) ? 3 : 1
            if n > 1, quotes.contains(t.character(at: 0)) { mark(0, triple, "punctuation.definition.string.begin") }
            if n > 1, quotes.contains(t.character(at: n - 1)) { mark(n - triple, triple, "punctuation.definition.string.end") }
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
        } else if scope == "constant.other.datetime.toml" || scope == "constant.other.time.toml" {
            // 2026-10-01T08:00:00Z: the separators plain, the zone a modifier.
            each(#"(?<=\d)-(?=\d)"#) { mark($0.range.location, 1, "punctuation.separator.date.toml") }
            each(#"(?<=\d)[Tt ](?=\d)"#) { mark($0.range.location, 1, "punctuation.separator.datetime.toml") }
            each(":") { mark($0.range.location, 1, "punctuation.separator.time.toml") }
            each(#"(?<=\d)\.(?=\d)"#) { mark($0.range.location, 1, "punctuation.separator.decimal.toml") }
            each(#"[Zz]$"#) { mark($0.range.location, 1, "storage.modifier.timezone.toml") }
        } else if scope.hasSuffix("source.regexp.python") {
            // A raw string, as a regular expression: classes like \d, the any-character dot and
            // anchors are keywords to Sublime; the rest is plain.
            each(#"\\[dDwWsSbBAZ]"#) { mark($0.range.location, 2, "keyword.control.character-class.regexp") }
            each(#"(?<!\\)\."#) { mark($0.range.location, 1, "keyword.other.any.regexp") }
            each(#"(?<!\\)[\^$]"#) { mark($0.range.location, 1, "keyword.control.anchor.regexp") }
        } else if scope == "constant.other.format-spec.python", token.hasPrefix(":") {
            mark(0, 1, "punctuation.separator.format-spec.python")
        } else if scope == "string.unquoted.value.ini" {
            // A value's booleans, as Git Config's are, and its quotes.
            each(#"^\s*((?i:true|false|yes|no|on|off))\s*$"#) { mark($0.range(at: 1).location, $0.range(at: 1).length, "constant.language.ini") }
            each(#"^\s*(")[^"]*(")\s*$"#) { m in
                mark(m.range(at: 1).location, 1, "punctuation.definition.string.begin.ini")
                mark(m.range(at: 2).location, 1, "punctuation.definition.string.end.ini")
            }
        } else if scope == "meta.annotation.go" {
            // A struct tag, `xml:"title,attr"`: its backticks, each key and its quoted value.
            if n > 1 { mark(0, 1, "punctuation.definition.annotation.begin.go"); mark(n - 1, 1, "punctuation.definition.annotation.end.go") }
            each(#"([A-Za-z_][A-Za-z0-9_]*)(:)("[^"]*")"#) { m in
                mark(m.range(at: 1).location, m.range(at: 1).length, "variable.annotation.go")
                mark(m.range(at: 2).location, 1, "punctuation.separator.key-value.go")
                let value = m.range(at: 3)
                mark(value.location, value.length, "string.quoted.double.go")
                mark(value.location, 1, "punctuation.definition.string.begin.go")
                mark(NSMaxRange(value) - 1, 1, "punctuation.definition.string.end.go")
                each(",") { if NSLocationInRange($0.range.location, value) { mark($0.range.location, 1, "punctuation.separator.sequence.go") } }
            }
        } else if scope == "meta.format.rust" {
            // A format macro's string: {}, {title}, {:?}, {0:>8} (not {{ }}).
            each(#"(?<!\{)\{[A-Za-z0-9_.]*(?::[^{}]*)?\}(?!\})"#) { mark($0.range.location, $0.range.length, "constant.other.placeholder.rust") }
        } else if scope.hasPrefix("constant.numeric"), scope.hasSuffix(".rust") {
            // 0.75_f64: the type after the number (whose point is the number's, to Sublime).
            if let suffix = token.range(of: #"_?(?:[iu](?:8|16|32|64|128|size)|f32|f64)$"#, options: .regularExpression) {
                let at = token.distance(from: token.startIndex, to: suffix.lowerBound) + (token[suffix].hasPrefix("_") ? 1 : 0)
                mark(at, n - at, "storage.type.numeric.rust")
            }
        } else if scope == "meta.preprocessor.macro.value.c" {
            // A #define's value: its numbers, as Sublime reads them there.
            each(#"(?<![\w.])\d+(?:\.\d+)?[uUlLfF]*(?![\w.])"#) { mark($0.range.location, $0.range.length, "constant.numeric.value.c") }
        } else if scope == "meta.string.like.sql" {
            each("%") { mark($0.range.location, 1, "constant.other.wildcard.percent.sql") }   // LIKE '%draft%'
        } else if scope == "meta.interval.sql" {
            // INTERVAL '30 days': the string in it, a token of its own to the grammar.
            each(#"'[^']*'"#) { m in
                mark(m.range.location, m.range.length, "string.quoted.single.sql")
                mark(m.range.location, 1, "punctuation.definition.string.begin.sql")
                mark(NSMaxRange(m.range) - 1, 1, "punctuation.definition.string.end.sql")
            }
        } else if scope == "meta.link.restructuredtext" {
            // `the website <https://…>`_ and settings_: the title and the address, the marks plain.
            if let m = (try? NSRegularExpression(pattern: #"^`([^<`]*?)\s*(?:<([^>]*)>)?`_{1,2}$"#))?.firstMatch(in: token, range: NSRange(location: 0, length: n)) {
                if m.range(at: 1).length > 0 { mark(m.range(at: 1).location, m.range(at: 1).length, "string.other.link.title.restructuredtext") }
                if m.range(at: 2).location != NSNotFound { mark(m.range(at: 2).location, m.range(at: 2).length, "markup.underline.link.restructuredtext") }
            } else if token.hasSuffix("_") {
                mark(0, n - (token.hasSuffix("__") ? 2 : 1), "string.other.link.title.restructuredtext")
            }
        } else if scope == "meta.link.reference.def.restructuredtext" {
            // .. _settings: — the name between its marks.
            let start = token.hasPrefix("_") ? 1 : 0, end = token.hasSuffix(":") ? n - 1 : n
            if end > start { mark(start, end - start, "string.other.link.title.restructuredtext") }
        } else if scope == "meta.footnote.link.restructuredtext" {
            if token.hasSuffix("_") { mark(0, n - 1, "constant.other.footnote.link.restructuredtext") }   // [#]_
        } else if scope == "meta.diff.range.unified" {
            // @@ -12,9 +12,11 @@ export function parseFeed(xml) {: the section after the second @@.
            each(#"^@@ [^@]*@@ ?(.+)$"#) { mark($0.range(at: 1).location, $0.range(at: 1).length, "entity.name.section.diff") }
        } else if scope == "meta.range.unified.diff" {
            if n > 0 { mark(0, 1, "support.function.diff") }   // the range's - or +
            each(",") { mark($0.range.location, 1, "punctuation.separator.sequence.diff") }
        } else if scope == "meta.header.from-file.diff" || scope == "meta.header.to-file.diff" {
            if token == "/dev/null" { mark(0, n, "constant.language.null.diff") }
            else { each("/") { mark($0.range.location, 1, "punctuation.separator.path.diff") } }
        } else if scope == "meta.message.git.commit" {
            // "Fixes #142": the keyword, and the reference with its #.
            each(#"\b((?:[Cc]lose[sd]?|[Ff]ix(?:e[sd])?|[Rr]esolve[sd]?))\s+(#(\d+))"#) { m in
                mark(m.range(at: 1).location, m.range(at: 1).length, "keyword.other.resolved-issue.git")
                mark(m.range(at: 2).location, m.range(at: 2).length, "constant.other.reference.issue.git")
                mark(m.range(at: 2).location, 1, "punctuation.definition.reference.issue.git")
            }
        } else if scope == "keyword.other.change-list.git.commit" || scope == "markup.heading.git.commit", token.hasSuffix(":") {
            // "modified:" and "Changes to be committed:": the colon isn't the word's.
            mark(n - 1, 1, scope.hasPrefix("keyword") ? "punctuation.separator.key-value.change-list.git.commit" : "comment.line.git.commit")
        } else if scope == "entity.name.function.makefile" || scope == "string.unquoted.makefile" {
            each("%") { mark($0.range.location, 1, "variable.language.makefile") }   // a pattern rule's stem
        } else if scope == "meta.function-call.arguments.makefile" {
            each(",") { mark($0.range.location, 1, "punctuation.separator.makefile") }
            each(#"\*"#) { mark($0.range.location, 1, "constant.other.wildcard.asterisk.makefile") }
        } else if scope.hasPrefix("entity.name.pattern.git") {
            // A pattern's dots, which Sublime counts as separators, but not in a directory's
            // name (`.vscode/`, where `.DS_Store`'s is one).
            each(#"(?<!\\)\.(?![^/]*/)"#) { mark($0.range.location, 1, "punctuation.separator.path.glob.git") }
        } else if scope == "meta.brackets.git.attributes", n > 2 {
            mark(0, 1, "punctuation.definition.brackets.begin.git.attributes")
            mark(1, n - 2, "string.unquoted.git.attributes")
            mark(n - 1, 1, "punctuation.definition.brackets.end.git.attributes")
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
        } else if scope.hasSuffix(".localname.xml"), let colon = token.utf16.firstIndex(of: 0x3A) {
            // itunes:image: the namespace, then the colon (a name's localname is the rest).
            let at = token.utf16.distance(from: token.utf16.startIndex, to: colon)
            mark(0, at, String(scope.dropLast("localname.xml".count)) + "namespace.xml")
            mark(at, 1, "punctuation.separator.namespace.xml")
        } else if scope.hasPrefix("meta.tag.sgml.doctype"), scope.hasSuffix(".html") {
            each("(?i)(doctype)\\s+(\\w+)") { m in
                mark(m.range(at: 1).location, m.range(at: 1).length, "keyword.declaration.doctype.html")
                mark(m.range(at: 2).location, m.range(at: 2).length, "constant.language.doctype.html")
            }
        } else if scope.hasPrefix("comment.") {
            if scope.hasPrefix("comment.block.documentation"), !scope.hasSuffix(".python") {
                // JSDoc's @param an attribute name; Javadoc's @author and phpdoc's @return tags, as each has it.
                let tag = scope.hasSuffix(".java") ? "entity.name.tag.documentation.javadoc"
                    : scope.hasSuffix(".php") ? "entity.name.tag.documentation.phpdoc.php" : "entity.other.attribute-name.documentation"
                each(#"@[A-Za-z]+"#) { mark($0.range.location, $0.range.length, tag) }
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
            else if let open = token.range(of: #"^--\[=*\["#, options: .regularExpression) {   // Lua's --[[ … ]]
                let length = token.distance(from: open.lowerBound, to: open.upperBound)
                mark(0, length, "punctuation.definition.comment.begin")
                if n >= length + 2, token.hasSuffix("]") { mark(n - (length - 2), length - 2, "punctuation.definition.comment.end") }
            }
            else if token.hasPrefix("--"), scope.hasSuffix(".lua") || scope.hasSuffix(".sql") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix(".."), scope.hasSuffix(".restructuredtext") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix("///") || token.hasPrefix("//!") { mark(0, 3, "punctuation.definition.comment") }   // a doc comment's
            else if token.hasPrefix("//") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix("<!--") { mark(0, 4, "punctuation.definition.comment.begin"); if n > 6, token.hasSuffix("-->") { mark(n - 3, 3, "punctuation.definition.comment.end") } }
            else if token.hasPrefix("#!") { mark(0, 2, "punctuation.definition.comment") }
            else if token.hasPrefix("#") || token.hasPrefix(";") { mark(0, 1, "punctuation.definition.comment") }
        } else if scope.hasPrefix("keyword.control.at-rule"), token.hasPrefix("@") {
            mark(0, 1, "punctuation.definition.keyword")
        } else if scope.hasPrefix("constant.character.entity") || scope.hasPrefix("constant.character.escape"), token.hasPrefix("&") {
            // &#169; and &#x2014;: the # and x are the entity's marks too. XML's ; ends it. (JSX's
            // &rarr; is an escape to Sublime, with the same marks.)
            mark(0, token.hasPrefix("&#x") || token.hasPrefix("&#X") ? 3 : token.hasPrefix("&#") ? 2 : 1, "punctuation.definition.entity")
            if token.hasSuffix(";") { mark(n - 1, 1, scope.hasSuffix(".xml") ? "punctuation.terminator.entity.xml" : "punctuation.definition.entity") }
        } else if scope.hasPrefix("variable.parameter.xml"), token.hasPrefix("%") {
            mark(0, 1, "punctuation.definition.parameter.xml")
            if token.hasSuffix(";") { mark(n - 1, 1, "punctuation.terminator.parameter.xml") }
        } else if scope.hasPrefix("variable"), !scope.hasSuffix(".makefile"), !scope.hasSuffix(".swift"), token.hasPrefix("$") {
            mark(0, token.hasPrefix("${") ? 2 : 1, "punctuation.definition.variable")
        } else if scope.hasPrefix("variable.other.readwrite"), scope.hasSuffix(".ruby"), token.hasPrefix("@") {
            mark(0, token.hasPrefix("@@") ? 2 : 1, "punctuation.definition.variable.ruby")   // @feeds, @@count
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
        /// Stretches of it that are the host's (make's references in a recipe's shell): blanked
        /// for the embedded language's parser, which reads a word there, and colored by the host.
        var holes: [NSRange] = []
        /// Scopes each hole takes, over the embedded language's (`clear.` as in a query).
        var holeScopes: [String] = []
    }

    /// The embedded languages that touch `window` (a whole text when it's all of it).
    static func find(in root: Node, text: NSString, language: SyntaxLanguage, window: NSRange? = nil) -> [Injection] {
        if language == .php { return phpPage(root) }
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
            case (.makefile, "shell_text"?), (.makefile, "shell_command"?):
                // A recipe's shell, and $(shell …)'s; make's references in it are holes.
                var holes: [NSRange] = []
                node.enumerateChildren { if $0.isNamed { holes.append($0.range) } }
                found.append(Injection(range: node.range, language: .shell, scopes: ["source.shell.embedded.makefile"], holes: holes))
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

    /// A PHP file's HTML: one stretch of HTML over the whole file, its `text` nodes as they are
    /// and the PHP between them holes, as Sublime embeds PHP in HTML. None for PHP alone.
    static func phpPage(_ root: Node) -> [Injection] {
        var texts: [NSRange] = []
        func walk(_ node: Node) {
            if node.nodeType == "text" { texts.append(node.range); return }
            node.enumerateChildren { walk($0) }
        }
        walk(root)
        guard !texts.isEmpty else { return [] }
        let whole = root.range
        var holes: [NSRange] = [], at = whole.location
        for stretch in texts.sorted(by: { $0.location < $1.location }) {
            if stretch.location > at { holes.append(NSRange(location: at, length: stretch.location - at)) }
            at = max(at, NSMaxRange(stretch))
        }
        if at < NSMaxRange(whole) { holes.append(NSRange(location: at, length: NSMaxRange(whole) - at)) }
        return [Injection(range: whole, language: .html, scopes: ["text.html.php"], holes: holes,
                          holeScopes: ["clear.meta.embedded.php", "source.php.embedded.html"])]
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
            // XML by the names Sublime's Markdown gives it.
            "xml": (.xml, "xml", "text.xml"), "atom": (.xml, "xml", "text.xml"), "plist": (.xml, "xml", "text.xml"),
            "svg": (.xml, "xml", "text.xml"), "xjb": (.xml, "xml", "text.xml"), "xsd": (.xml, "xml", "text.xml"), "xsl": (.xml, "xml", "text.xml"),
            // HL8's, and the other names Sublime's Markdown has for these.
            "console": (.shell, "shell", "source.shell.bash"), "shell-script": (.shell, "shell", "source.shell.bash"),
            "node": (.javascript, "javascript", "source.js"), "jsonc": (.json, "json", "source.json"),
            "jsx": (.jsx, "jsx", "source.jsx"), "tsx": (.tsx, "tsx", "source.tsx"),
            "typescript": (.typescript, "typescript", "source.ts"), "ts": (.typescript, "typescript", "source.ts"), "tsnode": (.typescript, "typescript", "source.ts"),
            "diff": (.diff, "diff", "source.diff"), "udiff": (.diff, "diff", "source.diff"), "patch": (.diff, "diff", "source.diff"),
            "make": (.makefile, "makefile", "source.makefile"), "makefile": (.makefile, "makefile", "source.makefile"), "mf": (.makefile, "makefile", "source.makefile"),
            "python": (.python, "python", "source.python"), "python3": (.python, "python", "source.python"), "py": (.python, "python", "source.python"),
            "toml": (.toml, "toml", "source.toml"), "yaml": (.yaml, "yaml", "source.yaml"), "yml": (.yaml, "yaml", "source.yaml"),
            "go": (.go, "go", "source.go"), "golang": (.go, "go", "source.go"), "rust": (.rust, "rust", "source.rust"), "rs": (.rust, "rust", "source.rust"),
            "ruby": (.ruby, "ruby", "source.ruby"), "rb": (.ruby, "ruby", "source.ruby"), "rbx": (.ruby, "ruby", "source.ruby"),
            "java": (.java, "java", "source.java"), "c": (.c, "c", "source.c"), "h": (.c, "c", "source.c"), "lua": (.lua, "lua", "source.lua"),
            "sql": (.sql, "sql", "source.sql"),
            // Nib's own: Sublime's Markdown has no Swift.
            "swift": (.swift, "swift", "source.swift"),
        ]
        guard let (language, id, root) = table[name] else { return nil }
        return (language, ["markup.raw.code-fence.\(id).markdown-gfm", root])
    }
}
