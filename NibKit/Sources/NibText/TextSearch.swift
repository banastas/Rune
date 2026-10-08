// Find and replace (PRD ED7): plain or regular-expression search, match case, whole word,
// within a range (the selection), and replacing one match or all, with $1… in the
// replacement when it's a regular expression. Plain text in, ranges and new text out.

import Foundation

public struct SearchOptions: Sendable, Equatable {
    public var regex = false
    public var matchCase = false
    public var wholeWord = false

    public init(regex: Bool = false, matchCase: Bool = false, wholeWord: Bool = false) {
        self.regex = regex; self.matchCase = matchCase; self.wholeWord = wholeWord
    }
}

public enum TextSearch {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case badPattern(String)
        public var description: String {
            // The pattern as typed: in a regular expression, case matters.
            switch self { case .badPattern(let pattern): "NOT A REGULAR EXPRESSION · “\(pattern)”" }
        }
    }

    /// Stop counting past this many; the count reads "10,000+".
    public static let limit = 10_000

    static func expression(_ query: String, _ options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.matchCase { flags.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw Failure.badPattern(query)
        }
    }

    /// Every match in `range` (the whole text by default), in order, up to `limit`. Empty
    /// matches (`^`, `a*`) are left out: there's nothing to see or replace there.
    public static func matches(of query: String, in text: String, options: SearchOptions, within range: NSRange? = nil) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let regex = try expression(query, options)
        let s = text as NSString
        let scope = range.map { NSIntersectionRange($0, NSRange(location: 0, length: s.length)) } ?? NSRange(location: 0, length: s.length)
        var out: [NSRange] = []
        regex.enumerateMatches(in: text, options: [.withoutAnchoringBounds], range: scope) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            out.append(match.range)
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    /// What one match becomes: the replacement as typed, or with $1… for a regular expression.
    public static func replacement(for match: NSRange, in text: String, query: String, template: String, options: SearchOptions) throws -> String {
        guard options.regex else { return template }
        let regex = try expression(query, options)
        guard let found = regex.firstMatch(in: text, options: [.withoutAnchoringBounds], range: match) else { return template }
        return regex.replacementString(for: found, in: text, offset: 0, template: template)
    }

    /// Replace All: the new text, and how many were replaced. Plain replacements are taken
    /// as typed (a "$" is just a dollar sign).
    public static func replaceAll(_ query: String, with template: String, in text: String, options: SearchOptions, within range: NSRange? = nil) throws -> (text: String, count: Int) {
        let found = try matches(of: query, in: text, options: options, within: range)
        guard !found.isEmpty else { return (text, 0) }
        let regex = try expression(query, options)
        let out = NSMutableString(string: text)
        for match in found.reversed() {
            let with: String
            if options.regex, let result = regex.firstMatch(in: text, options: [.withoutAnchoringBounds], range: match) {
                with = regex.replacementString(for: result, in: text, offset: 0, template: template)
            } else {
                with = template
            }
            out.replaceCharacters(in: match, with: with)
        }
        return (out as String, found.count)
    }

    /// The match after (or before) `location`, wrapping around; its index in `matches`.
    public static func next(after location: Int, in matches: [NSRange], backwards: Bool = false) -> Int? {
        guard !matches.isEmpty else { return nil }
        if backwards {
            return matches.lastIndex { $0.location < location } ?? matches.count - 1
        }
        return matches.firstIndex { $0.location >= location } ?? 0
    }
}
