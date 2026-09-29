// Color schemes (PRD HL2, HL5, HL10): a `.tmTheme`'s or a `.sublime-color-scheme`'s globals
// and scoped rules, and the style a scope gets from them, resolved as Sublime resolves it:
// each property (text color, background, font style) from the best-ranked rule that sets it,
// ranked by TextMate's selector specificity, later rules winning ties; a background's
// `foreground_adjust` then changes the text color under it.

import Foundation

public struct RGBA: Sendable, Hashable, CustomStringConvertible {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA".
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let v = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(r: Double(v >> 24 & 0xFF) / 255, g: Double(v >> 16 & 0xFF) / 255, b: Double(v >> 8 & 0xFF) / 255, a: Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB", or "#RRGGBBAA" when not opaque.
    public var hex: String {
        func byte(_ x: Double) -> String { String(format: "%02X", Int((x * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b) + (a < 1 ? byte(a) : "")
    }

    public var description: String { hex }
}

public struct Style: Sendable, Equatable {
    public var foreground: RGBA
    public var background: RGBA?
    public var bold = false
    public var italic = false
    public var underline = false
}

/// A TextMate scope selector: descendants (space), unions (`,`), exclusions (`-`) and
/// grouping (parentheses). Matched against a scope stack, outermost first.
public struct ScopeSelector: Sendable {
    indirect enum Node: Sendable {
        case path([String])            // atoms, outermost first: "source.js meta.function"
        case union([Node])
        case exclude(Node, Node)
        case empty
    }

    let root: Node

    public init(_ text: String) {
        var parser = Parser(tokens: Self.tokens(text))
        root = parser.union()
    }

    /// How strongly the selector matches `stack` (bigger is more specific), or nil.
    public func match(_ stack: [String]) -> Double? { Self.match(root, stack) }

    static func match(_ node: Node, _ stack: [String]) -> Double? {
        switch node {
        case .empty: return nil
        case .path(let atoms): return matchPath(atoms, stack)
        case .union(let nodes): return nodes.compactMap { match($0, stack) }.max()
        case .exclude(let keep, let drop): return match(drop, stack) == nil ? match(keep, stack) : nil
        }
    }

    /// Atoms match scopes in order, each a dot-segment prefix of its scope, each as deep in the
    /// stack as it can (the last atom first, from the innermost scope out); each counts its
    /// segments, weighted by how deep it matched (TextMate's ranking). Matching from the inside
    /// matters when a scope repeats: `string` in "string … variable … string" is the inner one.
    static func matchPath(_ atoms: [String], _ stack: [String]) -> Double? {
        guard !atoms.isEmpty else { return nil }
        var next = atoms.count - 1, score = 0.0
        for depth in stack.indices.reversed() where isPrefix(atoms[next], of: stack[depth]) {
            score += Double(atoms[next].split(separator: ".").count) * pow(2, Double(3 * depth))
            if next == 0 { return score }
            next -= 1
        }
        return nil
    }

    static func isPrefix(_ atom: String, of scope: String) -> Bool {
        atom == scope || scope.hasPrefix(atom + ".")
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = [], word = ""
        func flush() { if !word.isEmpty { out.append(word); word = "" } }
        for c in text {
            if c == "," || c == "(" || c == ")" || c == "|" { flush(); out.append(String(c)) }
            else if c == "-" && word.isEmpty { out.append("-") }   // "-" starts a word only as an exclusion
            else if c.isWhitespace { flush() }
            else { word.append(c) }
        }
        flush()
        return out
    }

    struct Parser {
        let tokens: [String]
        var i = 0

        init(tokens: [String]) { self.tokens = tokens }

        mutating func union() -> Node {
            var parts = [difference()]
            while i < tokens.count, tokens[i] == "," || tokens[i] == "|" { i += 1; parts.append(difference()) }
            return parts.count == 1 ? parts[0] : .union(parts)
        }

        mutating func difference() -> Node {
            var node = sequence()
            while i < tokens.count, tokens[i] == "-" { i += 1; node = .exclude(node, sequence()) }
            return node
        }

        /// A path, or a group; a group followed by more atoms is treated as the group (rare in schemes).
        mutating func sequence() -> Node {
            var atoms: [String] = []
            while i < tokens.count {
                let t = tokens[i]
                if t == "(" {
                    i += 1
                    let inner = union()
                    if i < tokens.count, tokens[i] == ")" { i += 1 }
                    if atoms.isEmpty { return inner }
                    continue
                }
                if t == ")" || t == "," || t == "|" || t == "-" { break }
                atoms.append(t)
                i += 1
            }
            return atoms.isEmpty ? .empty : .path(atoms)
        }
    }
}

public struct Theme: Sendable {
    public struct Rule: Sendable {
        public var name: String?
        public var scope: String
        public var selector: ScopeSelector
        public var foreground: RGBA?
        public var background: RGBA?
        /// nil: the rule doesn't set it; "" sets it to plain.
        public var fontStyle: String?
        /// `foreground_adjust`: how the text color changes where this rule's background is drawn.
        public var foregroundAdjust: [ColorAdjuster] = []
    }

    public var name: String
    /// The globals by `.sublime-color-scheme`'s names (a `.tmTheme`'s `lineHighlight` is
    /// `line_highlight`), colors as hex; options such as `brackets_options` as written.
    public var globals: [String: String]
    public var rules: [Rule]
    /// What was read only approximately ("GRADIENT TEXT AS ITS FIRST COLOR"), and the colors
    /// that couldn't be read at all, for the import report (HL4).
    public var approximations: [String] = []
    public var unread: [String] = []

    public var foreground: RGBA { globals["foreground"].flatMap(RGBA.init(hex:)) ?? RGBA(r: 1, g: 1, b: 1) }
    public var background: RGBA { globals["background"].flatMap(RGBA.init(hex:)) ?? RGBA(r: 0, g: 0, b: 0) }
    /// A global color, if the scheme sets one.
    public func color(_ global: String) -> RGBA? { globals[global].flatMap(RGBA.init(hex:)) }

    public enum ThemeError: Error { case notATheme }

    /// A `.tmTheme`: a property list whose `settings` are the globals first, then the rules.
    public init(tmTheme data: Data) throws {
        try self.init(document: Self.document(tmTheme: data), fallbackName: "Untitled")
    }

    /// A `.sublime-color-scheme`: JSON with comments and trailing commas; `variables`,
    /// `globals`, `rules`. Named after the file when it has no `name`.
    public init(sublimeColorScheme data: Data, fallbackName: String = "Untitled") throws {
        try self.init(document: Self.document(sublimeColorScheme: data), fallbackName: fallbackName)
    }

    // MARK: Documents
    //
    // Both formats become one shape, `.sublime-color-scheme`'s, before their colors are worked
    // out: so a `.tmTheme` takes a `.sublime-color-scheme` override as Sublime lets it (HL3),
    // and Nib keeps every imported scheme as one of these, variables and all.

    public static func document(tmTheme data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["settings"] as? [[String: Any]] else { throw ThemeError.notATheme }
        var globals: [String: Any] = [:], rules: [[String: Any]] = []
        for item in items {
            guard let settings = item["settings"] as? [String: Any] else { continue }
            guard let scope = item["scope"] as? String else {
                for (key, value) in settings { globals[snakeCase(key)] = value }
                continue
            }
            var rule: [String: Any] = ["scope": scope]
            if let name = item["name"] { rule["name"] = name }
            if let foreground = settings["foreground"] { rule["foreground"] = foreground }
            if let background = settings["background"] { rule["background"] = background }
            if let style = settings["fontStyle"] { rule["font_style"] = style }
            rules.append(rule)
        }
        var document: [String: Any] = ["globals": globals, "rules": rules]
        if let name = plist["name"] { document["name"] = name }
        if let author = plist["author"] { document["author"] = author }
        return document
    }

    public static func document(sublimeColorScheme data: Data) throws -> [String: Any] {
        let object = try LenientJSON.object(from: data)
        guard object["rules"] is [Any] || object["globals"] is [String: Any] else { throw ThemeError.notATheme }
        return object
    }

    /// Sublime's overrides: the override's variables and globals replace the base's, its
    /// rules come after the base's (so they win ties).
    public static func merging(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var out = base
        for key in ["variables", "globals"] {
            var merged = base[key] as? [String: Any] ?? [:]
            for (name, value) in override[key] as? [String: Any] ?? [:] { merged[name] = value }
            out[key] = merged
        }
        out["rules"] = (base["rules"] as? [Any] ?? []) + (override["rules"] as? [Any] ?? [])
        return out
    }

    static func snakeCase(_ key: String) -> String {
        var out = ""
        for c in key {
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
        return out
    }

    /// A scheme from a document in `.sublime-color-scheme`'s shape.
    public init(document: [String: Any], fallbackName: String) throws {
        name = (document["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        let variables = (document["variables"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        var colors = SchemeColors(variables: variables)
        var approximations: Set<String> = [], unread: [String] = []
        func looksLikeColor(_ text: String) -> Bool { text.hasPrefix("#") || text.contains("(") }
        func color(_ value: Any?, _ label: String) -> RGBA? {
            var value = value
            if let list = value as? [Any] {   // hashed or gradient text: several colors
                approximations.insert("GRADIENT TEXT AS ITS FIRST COLOR")
                value = list.first
            }
            guard let text = value as? String else { return nil }
            if let c = colors.color(text) { return c }
            unread.append("\(label) “\(text)”")
            return nil
        }
        globals = [:]
        for (key, value) in document["globals"] as? [String: Any] ?? [:] {
            let text = "\(value)"
            if let c = colors.color(text) { globals[key] = c.hex }
            else {
                if looksLikeColor(text) { unread.append("\(key) “\(text)”") }
                globals[key] = text
            }
        }
        rules = []
        for item in document["rules"] as? [Any] ?? [] {
            guard let rule = item as? [String: Any], let scope = rule["scope"] as? String else { continue }
            let label = (rule["name"] as? String) ?? scope
            var style = rule["font_style"] as? String
            if let words = style?.split(separator: " ").map(String.init) {
                var kept: [String] = []
                for word in words {
                    switch word {
                    case "bold", "italic", "underline": kept.append(word)
                    case "stippled_underline", "squiggly_underline":
                        approximations.insert("STIPPLED AND SQUIGGLY UNDERLINES AS UNDERLINE")
                        kept.append("underline")
                    case "glow": approximations.insert("GLOW LEFT OUT")
                    default: break
                    }
                }
                style = kept.joined(separator: " ")
            }
            var adjust: [ColorAdjuster] = []
            if let text = rule["foreground_adjust"] as? String {
                if let read = colors.adjusters(text) { adjust = read } else { unread.append("\(label) “\(text)”") }
            }
            rules.append(Rule(name: rule["name"] as? String, scope: scope, selector: ScopeSelector(scope),
                              foreground: color(rule["foreground"], label), background: color(rule["background"], label),
                              fontStyle: style, foregroundAdjust: adjust))
        }
        self.approximations = Array(approximations.union(colors.approximations)).sorted()
        self.unread = unread
    }

    /// The style for a scope stack ("source.js meta.function.js entity.name.function.js").
    public func style(for scopes: String) -> Style {
        style(for: scopes.split(separator: " ").map(String.init))
    }

    public func style(for stack: [String]) -> Style {
        var fg: (Double, RGBA)?, bg: (Double, RGBA, Int)?, font: (Double, String)?
        for (index, rule) in rules.enumerated() {
            guard let score = rule.selector.match(stack) else { continue }
            if let color = rule.foreground, score >= fg?.0 ?? -1 { fg = (score, color) }
            if let color = rule.background, score >= bg?.0 ?? -1 { bg = (score, color, index) }
            if let style = rule.fontStyle, score >= font?.0 ?? -1 { font = (score, style) }
        }
        var text = fg?.1 ?? foreground
        if let bg { for adjuster in rules[bg.2].foregroundAdjust { text = adjuster.apply(to: text) } }
        let words = Set((font?.1 ?? "").split(separator: " ").map(String.init))
        return Style(foreground: text, background: bg?.1,
                     bold: words.contains("bold"), italic: words.contains("italic"), underline: words.contains("underline"))
    }

    /// A light background: Nib's windows stay dark anyway (A17, HL4).
    public var isLight: Bool { background.contrast(RGBA(r: 0, g: 0, b: 0)) > background.contrast(RGBA(r: 1, g: 1, b: 1)) }
}

extension Theme {
    /// A scheme file's document, by its extension (`.tmTheme`, `.sublime-color-scheme`, and
    /// Sublime's `.hidden-tmTheme` and `.hidden-color-scheme`), named after the file if it isn't.
    public static func document(file data: Data, named fileName: String) throws -> [String: Any] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var document = ext.hasSuffix("tmtheme") ? try document(tmTheme: data) : try document(sublimeColorScheme: data)
        if (document["name"] as? String)?.isEmpty ?? true { document["name"] = (fileName as NSString).deletingPathExtension }
        return document
    }

    /// A document as Nib keeps it: a `.sublime-color-scheme`, variables and all.
    public static func storable(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: SublimeImport.jsonSafe(document), options: [.prettyPrinted, .sortedKeys])
    }
}
