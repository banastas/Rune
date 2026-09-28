// Color schemes (PRD HL2, HL5, HL10): a `.tmTheme`'s globals and scoped rules, and the
// style a scope gets from them, resolved as Sublime resolves it: each property (text color,
// background, font style) from the best-ranked rule that sets it, ranked by TextMate's
// selector specificity, later rules winning ties.

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
    }

    public var name: String
    /// The globals, as the scheme names them (`background`, `foreground`, `caret`, `lineHighlight`, …).
    public var globals: [String: String]
    public var rules: [Rule]

    public var foreground: RGBA { globals["foreground"].flatMap(RGBA.init(hex:)) ?? RGBA(r: 1, g: 1, b: 1) }
    public var background: RGBA { globals["background"].flatMap(RGBA.init(hex:)) ?? RGBA(r: 0, g: 0, b: 0) }

    public enum ThemeError: Error { case notATheme }

    /// A `.tmTheme`: a property list whose `settings` are the globals first, then the rules.
    public init(tmTheme data: Data) throws {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["settings"] as? [[String: Any]] else { throw ThemeError.notATheme }
        name = plist["name"] as? String ?? "Untitled"
        globals = [:]
        rules = []
        for item in items {
            guard let settings = item["settings"] as? [String: Any] else { continue }
            guard let scope = item["scope"] as? String else {
                for (key, value) in settings { if let text = value as? String { globals[key] = text } }
                continue
            }
            rules.append(Rule(name: item["name"] as? String, scope: scope, selector: ScopeSelector(scope),
                              foreground: (settings["foreground"] as? String).flatMap(RGBA.init(hex:)),
                              background: (settings["background"] as? String).flatMap(RGBA.init(hex:)),
                              fontStyle: settings["fontStyle"] as? String))
        }
    }

    /// The style for a scope stack ("source.js meta.function.js entity.name.function.js").
    public func style(for scopes: String) -> Style {
        style(for: scopes.split(separator: " ").map(String.init))
    }

    public func style(for stack: [String]) -> Style {
        var fg: (Double, RGBA)?, bg: (Double, RGBA)?, font: (Double, String)?
        for rule in rules {
            guard let score = rule.selector.match(stack) else { continue }
            if let color = rule.foreground, score >= fg?.0 ?? -1 { fg = (score, color) }
            if let color = rule.background, score >= bg?.0 ?? -1 { bg = (score, color) }
            if let style = rule.fontStyle, score >= font?.0 ?? -1 { font = (score, style) }
        }
        let words = Set((font?.1 ?? "").split(separator: " ").map(String.init))
        return Style(foreground: fg?.1 ?? foreground, background: bg?.1,
                     bold: words.contains("bold"), italic: words.contains("italic"), underline: words.contains("underline"))
    }
}
