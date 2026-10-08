// Colors as `.sublime-color-scheme` writes them (PRD HL2): hex with or without alpha,
// `rgb()`/`rgba()`, `hsl()`/`hsla()`, `hwb()`, CSS named colors, `var()`, and `color()` with
// Sublime's adjusters: `alpha()`/`a()`, `lightness()`/`l()`, `saturation()`/`s()`,
// `blend()`, `blenda()` and `min-contrast()`. Also WCAG contrast, for the import report (HL4).

import Foundation

/// A change to a color, from `color(… <adjuster>)` or a rule's `foreground_adjust`.
public enum ColorAdjuster: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case set(Double), add(Double), multiply(Double)

        func apply(to value: Double) -> Double {
            switch self {
            case .set(let v): v
            case .add(let v): value + v
            case .multiply(let v): value * v
            }
        }
    }

    case alpha(Change)
    case lightness(Change)
    case saturation(Change)
    /// Keeps `weight` of the base color (0…1) and takes the rest from `color`; `alpha` blends
    /// the alpha channel too (`blenda`); `hsl` mixes in HSL rather than RGB.
    case blend(RGBA, weight: Double, alpha: Bool, hsl: Bool)
    case minContrast(RGBA, ratio: Double)

    public func apply(to color: RGBA) -> RGBA {
        switch self {
        case .alpha(let change):
            var c = color
            c.a = min(1, max(0, change.apply(to: color.a)))
            return c
        case .lightness(let change):
            var hsl = color.hsl
            hsl.l = min(1, max(0, change.apply(to: hsl.l)))
            return RGBA(hue: hsl.h, saturation: hsl.s, lightness: hsl.l, alpha: color.a)
        case .saturation(let change):
            var hsl = color.hsl
            hsl.s = min(1, max(0, change.apply(to: hsl.s)))
            return RGBA(hue: hsl.h, saturation: hsl.s, lightness: hsl.l, alpha: color.a)
        case .blend(let other, let weight, let alpha, let hsl):
            let w = min(1, max(0, weight))
            func mix(_ a: Double, _ b: Double) -> Double { a * w + b * (1 - w) }
            var out: RGBA
            if hsl {
                let a = color.hsl, b = other.hsl
                var dh = b.h - a.h
                if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
                let h = (a.h + dh * (1 - w)).truncatingRemainder(dividingBy: 360)
                out = RGBA(hue: h < 0 ? h + 360 : h, saturation: mix(a.s, b.s), lightness: mix(a.l, b.l), alpha: color.a)
            } else {
                out = RGBA(r: mix(color.r, other.r), g: mix(color.g, other.g), b: mix(color.b, other.b), a: color.a)
            }
            if alpha { out.a = mix(color.a, other.a) }
            return out
        case .minContrast(let against, let ratio):
            if color.contrast(against) >= ratio { return color }
            // Lighter against a dark color, darker against a light one; the other way if that runs out.
            let lighter = against.luminance < 0.5
            for direction in lighter ? [1.0, -1.0] : [-1.0, 1.0] {
                var hsl = color.hsl
                while hsl.l >= 0, hsl.l <= 1 {
                    let candidate = RGBA(hue: hsl.h, saturation: hsl.s, lightness: hsl.l, alpha: color.a)
                    if candidate.contrast(against) >= ratio { return candidate }
                    hsl.l += direction * 0.005
                }
            }
            return color
        }
    }
}

extension RGBA {
    /// HSL, hue in degrees, saturation and lightness 0…1.
    public var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h, s, l)
    }

    public init(hue: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { self.init(r: l, g: l, b: l, a: alpha); return }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(r: channel(h + 1.0 / 3), g: channel(h), b: channel(h - 1.0 / 3), a: alpha)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio against another color (1…21), this color's alpha laid over it.
    public func contrast(_ other: RGBA) -> Double {
        let a = over(other).luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color laid over an opaque one, as it's drawn.
    public func over(_ below: RGBA) -> RGBA {
        guard a < 1 else { return self }
        return RGBA(r: r * a + below.r * (1 - a), g: g * a + below.g * (1 - a), b: b * a + below.b * (1 - a), a: 1)
    }
}

/// Reads color expressions against a scheme's variables.
public struct SchemeColors {
    public let variables: [String: String]
    /// What was read only approximately ("HWB BLENDS"), for the report.
    public private(set) var approximations: Set<String> = []

    public init(variables: [String: String] = [:]) { self.variables = variables }

    /// The color an expression names, or nil if it isn't one (an option like "underline").
    public mutating func color(_ text: String) -> RGBA? {
        var parser = Parser(chars: Array(text.unicodeScalars), variables: variables, depth: 0)
        let color = parser.color()
        approximations.formUnion(parser.approximations)
        parser.skipSpace()
        return parser.atEnd ? color : nil
    }

    /// The adjusters in a rule's `foreground_adjust` ("l(- 20%)"), or nil if one isn't read.
    public mutating func adjusters(_ text: String) -> [ColorAdjuster]? {
        var parser = Parser(chars: Array(text.unicodeScalars), variables: variables, depth: 0)
        var out: [ColorAdjuster] = []
        while true {
            parser.skipSpace()
            if parser.atEnd { break }
            guard let adjuster = parser.adjuster() else { return nil }
            out.append(adjuster)
        }
        approximations.formUnion(parser.approximations)
        return out
    }

    struct Parser {
        let chars: [Unicode.Scalar]
        let variables: [String: String]
        let depth: Int
        var i = 0
        var approximations: Set<String> = []

        init(chars: [Unicode.Scalar], variables: [String: String], depth: Int) {
            self.chars = chars; self.variables = variables; self.depth = depth
        }

        var atEnd: Bool { i >= chars.count }
        var peek: Unicode.Scalar? { i < chars.count ? chars[i] : nil }

        mutating func skipSpace() { while let c = peek, c == " " || c == "\t" || c == "\n" || c == "," { i += 1 } }
        mutating func skipBlanks() { while let c = peek, c == " " || c == "\t" || c == "\n" { i += 1 } }

        mutating func ident() -> String {
            var s = ""
            while let c = peek, CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" { s.unicodeScalars.append(c); i += 1 }
            return s
        }

        mutating func expect(_ c: Unicode.Scalar) -> Bool {
            skipBlanks()
            guard peek == c else { return false }
            i += 1
            return true
        }

        /// A number with an optional sign and unit ("50%", "-0.2", "210deg").
        mutating func number() -> (value: Double, percent: Bool)? {
            skipBlanks()
            var s = ""
            if let c = peek, c == "-" || c == "+" { s.unicodeScalars.append(c); i += 1 }
            while let c = peek, CharacterSet.decimalDigits.contains(c) || c == "." { s.unicodeScalars.append(c); i += 1 }
            guard let value = Double(s) else { return nil }
            if peek == "%" { i += 1; return (value, true) }
            _ = ident()   // deg
            return (value, false)
        }

        mutating func color() -> RGBA? {
            skipBlanks()
            if peek == "#" {
                i += 1
                var digits = ""
                while let c = peek, CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(c) { digits.unicodeScalars.append(c); i += 1 }
                if digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }   // #RGBA
                return RGBA(hex: "#" + digits)
            }
            let name = ident().lowercased()
            guard !name.isEmpty else { return nil }
            guard peek == "(" else { return namedColors[name] }
            i += 1
            switch name {
            case "var":
                skipBlanks()
                let variable = ident()
                guard expect(")"), depth < 16, let text = variables[variable] else { return nil }
                var inner = Parser(chars: Array(text.unicodeScalars), variables: variables, depth: depth + 1)
                let color = inner.color()
                approximations.formUnion(inner.approximations)
                return color
            case "rgb", "rgba", "hsl", "hsla", "hwb":
                var values: [(value: Double, percent: Bool)] = []
                while true {
                    skipBlanks()
                    if peek == "," || peek == "/" { i += 1; continue }
                    if peek == ")" { i += 1; break }
                    guard let n = number() else { return nil }
                    values.append(n)
                }
                guard values.count == 3 || values.count == 4 else { return nil }
                let alpha = values.count == 4 ? (values[3].percent ? values[3].value / 100 : values[3].value) : 1
                func unit(_ v: (value: Double, percent: Bool)) -> Double { v.percent ? v.value / 100 : v.value }
                switch name {
                case "rgb", "rgba":
                    func channel(_ v: (value: Double, percent: Bool)) -> Double { v.percent ? v.value / 100 : v.value / 255 }
                    return RGBA(r: channel(values[0]), g: channel(values[1]), b: channel(values[2]), a: alpha)
                case "hwb":
                    let w = unit(values[1]), b = unit(values[2])
                    let pure = RGBA(hue: values[0].value, saturation: 1, lightness: 0.5)
                    let scale = max(0, 1 - w - b)
                    return RGBA(r: pure.r * scale + w, g: pure.g * scale + w, b: pure.b * scale + w, a: alpha)
                default:
                    return RGBA(hue: values[0].value, saturation: unit(values[1]), lightness: unit(values[2]), alpha: alpha)
                }
            case "color":
                guard var base = color() else { return nil }
                while true {
                    skipBlanks()
                    if peek == ")" { i += 1; return base }
                    guard let adjuster = adjuster() else { return nil }
                    base = adjuster.apply(to: base)
                }
            default:
                return nil
            }
        }

        /// `alpha(0.5)`, `a(+ 10%)`, `l(- 20%)`, `s(* 1.1)`, `blend(#fff 50%)`, `blenda(var(x) 30% hsl)`, `min-contrast(var(bg) 4.5)`.
        mutating func adjuster() -> ColorAdjuster? {
            skipBlanks()
            let name = ident().lowercased()
            guard expect("(") else { return nil }
            let result: ColorAdjuster?
            switch name {
            case "alpha", "a", "lightness", "l", "saturation", "s":
                skipBlanks()
                var op: Unicode.Scalar?
                if let c = peek, c == "+" || c == "-" || c == "*" {
                    // "- 20%" is a change; "-20%" would be a set to a negative number (clamped).
                    if i + 1 < chars.count, chars[i + 1] == " " || c == "*" { op = c; i += 1 }
                }
                guard let n = number() else { return nil }
                let v = n.percent ? n.value / 100 : n.value
                let change: ColorAdjuster.Change = switch op {
                case "+": .add(v)
                case "-": .add(-v)
                case "*": .multiply(n.percent ? n.value / 100 : n.value)
                default: .set(v)
                }
                switch name {
                case "alpha", "a": result = .alpha(change)
                case "lightness", "l": result = .lightness(change)
                default: result = .saturation(change)
                }
            case "blend", "blenda":
                guard let other = color(), let n = number() else { return nil }
                skipBlanks()
                let space = ident().lowercased()
                if space == "hwb" { approximations.insert("HWB BLENDS AS RGB") }
                result = .blend(other, weight: n.percent ? n.value / 100 : n.value, alpha: name == "blenda", hsl: space == "hsl")
            case "min-contrast":
                guard let other = color(), let n = number() else { return nil }
                result = .minContrast(other, ratio: n.value)
            default:
                return nil
            }
            guard expect(")") else { return nil }
            return result
        }
    }
}

/// CSS's named colors, which `.sublime-color-scheme` accepts.
let namedColors: [String: RGBA] = {
    let list = """
    aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 \
    black 000000 blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 \
    chartreuse 7fff00 chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff \
    darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 \
    darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 \
    darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f \
    darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 \
    dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc \
    ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f grey 808080 \
    honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa \
    lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
    lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 \
    lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 \
    lightsteelblue b0c4de lightyellow ffffe0 lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 \
    mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 \
    mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc mediumvioletred c71585 \
    midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 \
    oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa \
    palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f \
    pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f \
    royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee \
    sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa \
    springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 \
    violet ee82ee wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32 transparent 00000000
    """
    let words = list.split(whereSeparator: { $0 == " " || $0 == "\n" })
    var out: [String: RGBA] = [:]
    for pair in stride(from: 0, to: words.count - 1, by: 2) { out[String(words[pair])] = RGBA(hex: "#" + words[pair + 1]) }
    return out
}()

extension Theme {
    /// The gutter behind line numbers (ED6): the scheme's `gutter`, or the background.
    public var gutter: RGBA { color("gutter") ?? background }

    /// Line numbers (ED6): the scheme's `gutter_foreground`, or else the text color dimmed
    /// toward the gutter as far as it stays at least 4.5:1 on it (Nib's own floor, A-series).
    public var gutterForeground: RGBA {
        if let set = color("gutter_foreground") { return set }
        let text = foreground, behind = gutter
        for step in stride(from: 12, through: 0, by: -1) {   // 60% toward the gutter, then less
            let t = Double(step) * 0.05
            let dimmed = RGBA(r: text.r + (behind.r - text.r) * t, g: text.g + (behind.g - text.g) * t, b: text.b + (behind.b - text.b) * t)
            if dimmed.contrast(behind) >= 4.5 { return dimmed }
        }
        return text
    }
}
