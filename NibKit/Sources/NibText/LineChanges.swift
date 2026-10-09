// Changes since the last commit (PRD ED12): which lines of the text differ from the committed
// version, as Sublime Text's mini diff marks them. Lines are matched as the merge matches them
// (`Merge.matches`); between two lines both versions share, lines only in the text are added, lines
// only in the commit are deleted (marked before the next shared line), and where both have lines,
// as many as the commit had are changed and the rest added.

import Foundation

public struct LineChanges: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case added, modified }

    /// By line of the text, from 0.
    public private(set) var lines: [Int: Kind] = [:]
    /// Lines of the text before which committed lines were deleted (the line count: at the end).
    public private(set) var deletedBefore: Set<Int> = []
    public private(set) var added = 0
    public private(set) var modified = 0
    public private(set) var deleted = 0

    public var isEmpty: Bool { lines.isEmpty && deletedBefore.isEmpty }

    public init() {}

    /// The text's lines against the committed text's, line endings set aside ("\r\n" as "\n").
    public static func between(committed: String, text: String) -> LineChanges {
        let base = split(committed), now = split(text)
        var changes = LineChanges()
        guard base != now else { return changes }
        let matched = Merge.matches(base, now)
        var previousBase = -1, previousNow = -1
        func gap(toBase i: Int, toNow j: Int) {
            let removed = i - previousBase - 1, inserted = j - previousNow - 1
            if inserted > 0 {
                for (k, line) in ((previousNow + 1)..<j).enumerated() {
                    let kind: Kind = k < removed ? .modified : .added
                    changes.lines[line] = kind
                    if kind == .modified { changes.modified += 1 } else { changes.added += 1 }
                }
            }
            if removed > inserted {
                changes.deleted += removed - inserted
                changes.deletedBefore.insert(j)
            }
        }
        for (i, j) in matched.enumerated() {
            guard let j else { continue }
            gap(toBase: i, toNow: j)
            previousBase = i
            previousNow = j
        }
        gap(toBase: base.count, toNow: now.count)
        return changes
    }

    /// Lines as the gutter counts them: a final newline ends the last line, not starts one.
    static func split(_ text: String) -> [Substring] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// "6 changed · 2 added · 1 deleted", or "no changes", in the HUD's words.
    public var summary: String {
        guard !isEmpty else { return "NO CHANGES SINCE THE LAST COMMIT" }
        var parts: [String] = []
        if modified > 0 { parts.append("\(modified) CHANGED") }
        if added > 0 { parts.append("\(added) ADDED") }
        if deleted > 0 { parts.append("\(deleted) DELETED") }
        return parts.joined(separator: " · ")
    }
}
