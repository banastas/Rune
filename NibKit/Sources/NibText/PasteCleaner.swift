// Plain-text paste (PRD PT1, PT3). M1 does what ⌘V needs: text only, any line
// endings made "\n". Paste Clean's invisible-character rules (M2) build on `clean`.

public enum PasteCleaner {
    /// What ⌘V inserts: the clipboard's plain text with "\n" line endings.
    public static func plain(_ text: String) -> String { TextFile.normalize(text) }

    /// Paste Clean (M2): also drops zero-width and bidi control characters, the BOM
    /// and soft hyphens, and turns non-breaking and other unusual spaces into spaces.
    public static func clean(_ text: String) -> (text: String, removed: Int) {
        var removed = 0
        var out = String.UnicodeScalarView()
        for scalar in plain(text).unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                removed += 1
            case 0x00A0, 0x2007, 0x202F, 0x2000...0x200A, 0x3000:
                removed += 1
                out.append(" ")
            default:
                out.append(scalar)
            }
        }
        return (String(out), removed)
    }
}
