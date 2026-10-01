// Keep Both (PRD SY6, §4.7): both versions in the file, the differing lines between
// standard conflict markers, so nothing is lost and git-aware tools recognize them.
// M1 compares two versions by line; M2 replaces this with a three-way merge.

public enum ConflictText {
    public struct Side: Sendable {
        public var text: String
        /// "Air · 10:42": the device and its own clock.
        public var label: String

        public init(text: String, label: String) {
            self.text = text
            self.label = label
        }
    }

    /// Common leading and trailing lines stay; the lines between go into one marked
    /// block. Sides are ordered by label, never "mine first", so two Macs keeping both
    /// of the same pair write the same bytes (PRD §4.7, deterministic output).
    public static func keepBoth(_ a: Side, _ b: Side) -> String {
        if a.text == b.text { return a.text }
        let (first, second) = a.label <= b.label ? (a, b) : (b, a)
        let x = lines(first.text), y = lines(second.text)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix,
              x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        var out = Array(x[..<prefix])
        out.append("<<<<<<< \(first.label)")
        out += x[prefix..<(x.count - suffix)]
        out.append("=======")
        out += y[prefix..<(y.count - suffix)]
        out.append(">>>>>>> \(second.label)")
        out += x[(x.count - suffix)...]
        return out.joined(separator: "\n")
    }

    /// Lines, keeping a final empty line when the text ends with "\n".
    /// Split at "\n" bytes: the same lines as splitting at the character (a line feed never
    /// joins a grapheme, and Nib's texts have "\n" line endings), without walking graphemes,
    /// which took 33 ms for each 2.4 MB text: 99 of a merge's 108 ms (§6.5, 2026-09-30).
    static func lines(_ text: String) -> [Substring] {
        text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Substring($0) }
    }

    /// True if the text holds conflict markers nib (or git) wrote.
    public static func hasMarkers(_ text: String) -> Bool {
        text.contains("\n<<<<<<< ") || text.hasPrefix("<<<<<<< ")
    }
}
