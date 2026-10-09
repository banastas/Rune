// Changes since the last commit (PRD ED12): which lines of the text differ from the committed
// version, as Sublime Text's mini diff marks them. Between two lines both versions share, lines
// only in the text are added, lines only in the commit are deleted (marked before the next shared
// line), and where both have lines, as many as the commit had are changed and the rest added.
//
// Lines are matched by Myers's diff with a cap on the edits it looks for (`limit`), not by the
// merge's `Merge.matches`: that one's work grows with the square of the lines when most of them
// differ (a 2 MB file with every line changed, 49 s of a core, again after every pause in typing).
// Past the cap, a quick count instead: each line whose text isn't anywhere in the commit is
// marked changed, nothing deleted (`approximate`), and the HUD says so (lines only moved, as by
// sorting, are in the commit: nothing marked, but not "no changes").

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

    /// Too many edits to match line by line: only lines not in the commit are marked.
    public private(set) var approximate = false

    public var isEmpty: Bool { lines.isEmpty && deletedBefore.isEmpty && !approximate }

    public init() {}

    /// Edits (a line in or a line out) looked for before giving up on matching line by line: at
    /// 5 MB (ED9's limit) that's well under a second.
    public static let limit = 2_000

    /// The text's lines against the committed text's, line endings set aside ("\r\n" as "\n").
    public static func between(committed: String, text: String, limit: Int = limit) -> LineChanges {
        let base = split(committed), now = split(text)
        var changes = LineChanges()
        guard base != now else { return changes }
        guard let matched = matches(base, now, limit: limit) else {
            let committed = Set(base)
            for (line, text) in now.enumerated() where !committed.contains(text) {
                changes.lines[line] = .modified
                changes.modified += 1
            }
            changes.approximate = true
            return changes
        }
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

    /// For each line of `base`, the line of `new` it's the same line as (nil: not in `new`), or
    /// nil when more than `limit` edits are needed. The lines both start and end with are matched
    /// first, then Myers's greedy search over what's between, a step for each edit.
    static func matches(_ base: [Substring], _ new: [Substring], limit: Int) -> [Int?]? {
        var result = [Int?](repeating: nil, count: base.count)
        var start = 0
        while start < base.count, start < new.count, base[start] == new[start] { result[start] = start; start += 1 }
        var endBase = base.count, endNew = new.count
        while endBase > start, endNew > start, base[endBase - 1] == new[endNew - 1] {
            endBase -= 1; endNew -= 1
            result[endBase] = endNew
        }
        // Lines as numbers, so comparing two is comparing two integers.
        var ids: [Substring: Int] = [:]
        let a = base[start..<endBase].map { line -> Int in
            if let id = ids[line] { return id }
            ids[line] = ids.count
            return ids.count - 1
        }
        let b = new[start..<endNew].map { ids[$0] ?? -1 }   // -1: in no line of the commit
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return result }
        let most = min(n + m, limit), offset = most + 1
        var v = [Int](repeating: 0, count: 2 * most + 3)   // by diagonal k (x - y): the furthest x
        var trace: [[Int]] = []                             // v after each step d, diagonals -d...d
        for d in 0...most {
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset])) ? v[k + 1 + offset] : v[k - 1 + offset] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[k + offset] = x
                guard x >= n, y >= m else { continue }
                // Back from the end along the steps taken, matching each diagonal's lines.
                for step in stride(from: d, to: 0, by: -1) {
                    let before = trace[step - 1], k = x - y, at = step - 1   // before[k + at] is diagonal k
                    let previous = (k == -step || (k != step && before[k - 1 + at] < before[k + 1 + at])) ? k + 1 : k - 1
                    let px = before[previous + at], py = px - previous
                    while x > px, y > py { x -= 1; y -= 1; result[start + x] = start + y }
                    x = px; y = py
                }
                while x > 0, y > 0 { x -= 1; y -= 1; result[start + x] = start + y }
                return result
            }
            trace.append(Array(v[(offset - d)...(offset + d)]))
        }
        return nil
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
        if approximate { return "MANY CHANGES SINCE THE LAST COMMIT" + (modified > 0 ? " · \(modified) NEW LINES MARKED" : "") }
        var parts: [String] = []
        if modified > 0 { parts.append("\(modified) CHANGED") }
        if added > 0 { parts.append("\(added) ADDED") }
        if deleted > 0 { parts.append("\(deleted) DELETED") }
        return parts.joined(separator: " · ")
    }
}
