// Closing brackets and quotes as they're typed (PRD ED10, Sublime's auto_match_enabled, on by
// default), by Sublime's own rules (its default keymap): an opener gets its closer when what
// follows is a space, a tab, the end of the line or a closer; a quote too, unless it follows a
// letter, a digit, an underscore or the same quote (an apostrophe in "don't" is only that). A
// selection is wrapped. A closer typed where the same closer already is steps over it; Backspace
// between an empty pair takes both; Return between brackets opens a line, indented, between.

import Foundation

public enum AutoPairs {
    public static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
    static let quotes: Set<Character> = ["\"", "'", "`"]
    static let closers: Set<Character> = [")", "]", "}", "\"", "'", "`"]

    public enum Action: Equatable, Sendable {
        /// `range` made `text`, then `selection` selected (in the text after it).
        case edit(range: NSRange, text: String, selection: NSRange)
        /// The caret to `to`, over a closer that's already there.
        case skip(to: Int)
    }

    /// What typing `typed` at `selection` does; nil for nothing more than typing it.
    public static func typing(_ typed: String, in text: NSString, selection: NSRange) -> Action? {
        guard typed.count == 1, let c = typed.first else { return nil }
        let after = NSMaxRange(selection)
        let next: Character? = after < text.length ? Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: after))) : nil
        let previous: Character? = selection.location > 0 ? Character(text.substring(with: text.rangeOfComposedCharacterSequence(at: selection.location - 1))) : nil
        if selection.length > 0 {
            // A selection: wrapped, and still selected inside.
            guard let close = pairs[c] else { return nil }
            let inner = text.substring(with: selection)
            return .edit(range: selection, text: String(c) + inner + String(close),
                         selection: NSRange(location: selection.location + 1, length: (inner as NSString).length))
        }
        // A closer, or a quote, where the same is already next: over it.
        if next == c, closers.contains(c) { return .skip(to: after + 1) }
        guard let close = pairs[c] else { return nil }
        let nextOK = next == nil || next == " " || next == "\t" || next == "\n" || next == ")" || next == "]" || next == "}" || next == ";" || next == ","
        guard nextOK else { return nil }
        if quotes.contains(c), let previous, previous.isLetter || previous.isNumber || previous == "_" || previous == c { return nil }
        return .edit(range: selection, text: String(c) + String(close), selection: NSRange(location: selection.location + 1, length: 0))
    }

    /// Backspace at `caret` between an empty pair: both characters.
    public static func deleting(in text: NSString, caret: Int) -> NSRange? {
        guard caret > 0, caret < text.length else { return nil }
        let before = Character(text.substring(with: NSRange(location: caret - 1, length: 1)))
        let after = Character(text.substring(with: NSRange(location: caret, length: 1)))
        guard pairs[before] == after else { return nil }
        return NSRange(location: caret - 1, length: 2)
    }

    /// Return at `caret` between (), [] or {}: a new line indented a step further, and the closer
    /// on a line of its own at the line's own indentation. The text to insert and the caret's
    /// place in it.
    public static func newline(in text: NSString, caret: Int, indent: String, unit: String) -> (text: String, caret: Int)? {
        guard caret > 0, caret < text.length else { return nil }
        let before = text.character(at: caret - 1), after = text.character(at: caret)
        guard Brackets.openers[before] == after else { return nil }
        let inner = "\n" + indent + unit
        return (inner + "\n" + indent, (inner as NSString).length)
    }
}
