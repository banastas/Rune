// Matching brackets (PRD ED10, Sublime's match_brackets and match_brackets_content, both on by
// default): the bracket beside the caret and its partner, or with none beside it, the pair the
// caret is in. (), [] and {}, not angle brackets (Sublime's match_brackets_angle is off by
// default). A scan of the text, a type at a time, so a bracket in a string or a comment counts
// as any other; it stops `limit` characters out either way.

import Foundation

public enum Brackets {
    public struct Match: Equatable, Sendable {
        /// The two brackets' offsets (UTF-16).
        public var open: Int
        public var close: Int
        /// The caret beside one of them (the scheme's `brackets_*`), or inside the pair (its
        /// `bracket_contents_*`).
        public var beside: Bool

        public init(open: Int, close: Int, beside: Bool) {
            self.open = open
            self.close = close
            self.beside = beside
        }
    }

    static let openers: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]   // ( [ {
    static let closers: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]   // ) ] }

    public static func match(in text: NSString, caret: Int, limit: Int = 50_000) -> Match? {
        let length = text.length
        guard caret >= 0, caret <= length else { return nil }
        let before: unichar? = caret > 0 ? text.character(at: caret - 1) : nil
        let after: unichar? = caret < length ? text.character(at: caret) : nil
        // Beside the caret: a closer just before it (the bracket just typed), an opener after it,
        // then the other two.
        if let c = before, closers[c] != nil, let open = backward(text, from: caret - 2, closer: c, limit: limit) {
            return Match(open: open, close: caret - 1, beside: true)
        }
        if let c = after, openers[c] != nil, let close = forward(text, from: caret + 1, opener: c, limit: limit) {
            return Match(open: caret, close: close, beside: true)
        }
        if let c = after, closers[c] != nil, let open = backward(text, from: caret - 1, closer: c, limit: limit) {
            return Match(open: open, close: caret, beside: true)
        }
        if let c = before, openers[c] != nil, let close = forward(text, from: caret, opener: c, limit: limit) {
            return Match(open: caret - 1, close: close, beside: true)
        }
        // Inside a pair: the nearest opener before the caret not closed before it, of any of the
        // three, and its own closer after.
        var depth: [unichar: Int] = [:]
        var at = caret - 1
        let stop = max(0, caret - limit)
        while at >= stop {
            let c = text.character(at: at)
            if let opener = closers[c] {
                depth[opener, default: 0] += 1
            } else if openers[c] != nil {
                if depth[c, default: 0] > 0 { depth[c, default: 0] -= 1 } else {
                    guard let close = forward(text, from: caret, opener: c, limit: limit) else { return nil }
                    return Match(open: at, close: close, beside: false)
                }
            }
            at -= 1
        }
        return nil
    }

    /// The closer of the opener `c`, from `from` on, its own type counted.
    static func forward(_ text: NSString, from: Int, opener c: unichar, limit: Int) -> Int? {
        guard let closer = openers[c] else { return nil }
        var depth = 0, at = from
        let stop = min(text.length, from + limit)
        while at < stop {
            let x = text.character(at: at)
            if x == c { depth += 1 } else if x == closer { if depth == 0 { return at }; depth -= 1 }
            at += 1
        }
        return nil
    }

    /// The opener of the closer `c`, from `from` back.
    static func backward(_ text: NSString, from: Int, closer c: unichar, limit: Int) -> Int? {
        guard let opener = closers[c] else { return nil }
        var depth = 0, at = from
        let stop = max(0, from - limit)
        while at >= stop {
            let x = text.character(at: at)
            if x == c { depth += 1 } else if x == opener { if depth == 0 { return at }; depth -= 1 }
            at -= 1
        }
        return nil
    }
}
