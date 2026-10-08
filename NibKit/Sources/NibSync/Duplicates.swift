// Duplicate files (PRD §4.6, 4; §4.8 C): a sibling named `<name> <n>.<ext>` (n ≥ 2, e.g.
// `scratch 2.md`), as iCloud Drive makes in some races, such as two Macs creating the
// same file. Only the name is decided here; what's in it, and whether it's new, is the
// document's business.

import Foundation

public enum Duplicates {
    /// "scratch 2.md" is one of "scratch.md"; "scratch 1.md", "scratch copy.md" and "scratch2.md" aren't.
    public static func isDuplicate(_ candidate: String, of name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let tail = ext.isEmpty ? "" : "." + ext
        guard candidate.hasPrefix(stem + " "), candidate.hasSuffix(tail) else { return false }
        let number = candidate.dropFirst(stem.count + 1).dropLast(tail.count)
        guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber), let n = Int(number) else { return false }
        return n >= 2 && !number.hasPrefix("0")
    }

    /// The duplicates beside `url` now, by name.
    public static func beside(_ url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { isDuplicate($0, of: url.lastPathComponent) }.sorted().map { folder.appendingPathComponent($0) }
    }
}
