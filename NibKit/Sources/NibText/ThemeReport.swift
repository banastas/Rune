// The import report (PRD HL4), in the HUD's words (W1, W2, W5): what was imported, which
// globals Nib draws and which it doesn't yet, every text color under 4.5:1 on its
// background, a light background, and anything read only approximately.
//
//   IMPORTED AN-OLD-HOPE · 42 RULES · 6 GLOBALS USED · 14 NOT DRAWN YET (BRACKETS, …) ·
//   4 COLORS UNDER 4.5:1: #7851A9 NUMBER 2.9, …

import Foundation

public enum ThemeReport {
    /// The globals Nib's editor draws (HL5); the rest are counted as not drawn yet.
    public static let drawn: Set<String> = ["background", "foreground", "caret", "selection", "inactive_selection", "line_highlight",
                                                  "find_highlight", "find_highlight_foreground"]

    /// The report's facts, in order; the caller adds its own (the font) and joins them with " · ".
    public static func facts(for theme: Theme) -> [String] {
        var facts = ["IMPORTED \(theme.name.uppercased())", "\(theme.rules.count) RULE\(theme.rules.count == 1 ? "" : "S")"]
        let used = theme.globals.keys.filter(drawn.contains)
        let notDrawn = theme.globals.keys.filter { !drawn.contains($0) }
        facts.append("\(used.count) GLOBAL\(used.count == 1 ? "" : "S") USED")
        if !notDrawn.isEmpty {
            let groups = Array(Set(notDrawn.map(group))).sorted { order($0) < order($1) }
            facts.append("\(notDrawn.count) NOT DRAWN YET (\(groups.joined(separator: ", ")))")
        }
        let low = lowContrast(theme)
        if low.isEmpty {
            facts.append("EVERY COLOR AT LEAST 4.5:1 ON THE BACKGROUND")
        } else {
            let list = low.map { item in
                let on = item.background.map { " ON \($0.hex)" } ?? ""
                return "\(item.color.hex)\(on) \(item.name.uppercased()) \(String(format: "%.1f", item.ratio))"
            }
            facts.append("\(low.count) COLOR\(low.count == 1 ? "" : "S") UNDER 4.5:1: \(list.joined(separator: ", "))")
        }
        if theme.isLight { facts.append("LIGHT BACKGROUND · NIB'S WINDOWS STAY DARK") }
        if !theme.approximations.isEmpty { facts.append("APPROXIMATED: \(theme.approximations.joined(separator: ", "))") }
        if !theme.unread.isEmpty { facts.append("\(theme.unread.count) COLOR\(theme.unread.count == 1 ? "" : "S") NOT READ: \(theme.unread.prefix(3).joined(separator: ", "))\(theme.unread.count > 3 ? ", …" : "")") }
        return facts
    }

    /// Text colors under 4.5:1, each color (on its own background, if its rule has one) once,
    /// named after the first rule that uses it; the scheme's own text color first.
    public static func lowContrast(_ theme: Theme) -> [(color: RGBA, background: RGBA?, name: String, ratio: Double)] {
        var out: [(color: RGBA, background: RGBA?, name: String, ratio: Double)] = []
        var seen: Set<String> = []
        let page = theme.background
        func check(_ color: RGBA, _ background: RGBA?, _ name: String) {
            let key = color.hex + (background?.hex ?? "")
            guard !seen.contains(key) else { return }
            seen.insert(key)
            let below = background.map { $0.over(page) } ?? page
            let ratio = color.contrast(below)
            if ratio < 4.5 { out.append((color, background, name, ratio)) }
        }
        check(theme.foreground, nil, "text")
        for rule in theme.rules {
            guard let color = rule.foreground ?? (rule.background != nil ? theme.foreground : nil) else { continue }
            check(color, rule.background, rule.name ?? rule.scope.split(separator: " ").first.map(String.init) ?? rule.scope)
        }
        return out
    }

    static func group(_ key: String) -> String {
        if key.hasPrefix("bracket") { return "BRACKETS" }
        if key.hasPrefix("tags") { return "TAGS" }
        if key.hasSuffix("guide") { return "GUIDES" }
        if key.hasPrefix("shadow") { return "SHADOW" }
        if key.hasPrefix("find_highlight") { return "FIND HIGHLIGHT" }
        if key.hasPrefix("gutter") { return "GUTTER" }
        return key.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    static func order(_ group: String) -> String {
        let first = ["BRACKETS", "TAGS", "GUIDES", "SELECTION BORDER", "SHADOW"]
        return first.firstIndex(of: group).map { "0\($0)" } ?? "1" + group
    }
}

extension Theme {
    /// The user's original An Old Hope, which Import from Sublime swaps for the Nib edition (HL10).
    public var isOriginalAnOldHope: Bool {
        name.lowercased().replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces) == "an old hope"
    }
}
