// The HUD's words as VoiceOver should say them (PRD V4, AX1, AX2): "✓ MERGED 2 CHANGES FROM
// AIR · ⌘Z UNDOES" is "Merged 2 changes from air, Command-Z undoes". Glyphs go (the words
// after them say the same), middle dots and › become commas, keys are named, and the
// capitals drop, so it isn't spelled out or shouted.

import Foundation

public enum Spoken {
    private static let glyphs: Set<String> = ["✓", "✕", "▲", "▼", "‖", "=", "◐", "→"]
    private static let modifiers: [Character: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
    private static let keys: [Character: String] = ["↩": "Return", "⎋": "Escape", "⌫": "Delete", "⇥": "Tab", "↑": "Up Arrow", "↓": "Down Arrow",
                                                    "←": "Left Arrow", "→": "Right Arrow"]
    /// Names that keep their capitals, as whole words.
    private static let names = ["iCloud Drive", "iCloud", "Rune", "Sublime Text", "Finder", "Mac", "M1", "PRD", "UTF-8", "LF", "CRLF"]

    public static func sentence(_ hud: String) -> String {
        let words = hud.split(separator: " ").map(String.init).filter { !glyphs.contains($0) }
        let text = words.joined(separator: " ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: " › ", with: ", ")
            .replacingOccurrences(of: "§", with: "section ")
        // Keys as words ("Command-Z"), kept apart from the lowering; the rest lowered.
        var out = "", run = "", pending: [String] = []
        func flush() { out += run.lowercased(); run = "" }
        for character in text {
            if let name = modifiers[character] { pending.append(name); continue }
            if !pending.isEmpty {
                flush()
                out += (pending + [keys[character] ?? String(character).uppercased()]).joined(separator: "-")
                pending = []
                continue
            }
            run.append(character)
        }
        flush()
        for name in names {
            out = out.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: name.lowercased()))\\b", with: name,
                                           options: .regularExpression)
        }
        guard let first = out.first else { return out }
        return first.uppercased() + out.dropFirst()
    }
}
