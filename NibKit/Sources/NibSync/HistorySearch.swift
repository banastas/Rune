// Find in History (PRD SY18): when Find has no matches in the text, the file's History searched
// for it, newest version first, with the find bar's options, stopping at the first version that
// has it: the most recent text that was lost. Versions are read by a loader the caller gives
// (History's `unverifiedData`, decoded), each SHA-256 once, and the search stops between
// versions when it's cancelled (the query changed).

import Foundation
import NibText

public enum HistorySearch {
    public enum Outcome: Equatable, Sendable {
        /// The newest version with a match, and its matches.
        case found(HistoryEntry, [NSRange])
        /// In none of the versions read; how many distinct versions that was.
        case nowhere(searched: Int)
        /// The query isn't a regular expression (only with the regex option).
        case badPattern
        case cancelled
    }

    /// `entries` oldest first, as `History.entries()` lists them. `load` gives a version's text,
    /// or nil when it can't be read (skipped).
    public static func newest(_ query: String, options: SearchOptions, in entries: [HistoryEntry],
                              load: (String) -> String?, isCancelled: () -> Bool = { false }) -> Outcome {
        guard !query.isEmpty else { return .nowhere(searched: 0) }
        var seen = Set<String>()
        for entry in entries.reversed() {
            if isCancelled() { return .cancelled }
            guard seen.insert(entry.sha256).inserted, let text = load(entry.sha256) else { continue }
            do {
                let found = try TextSearch.matches(of: query, in: text, options: options)
                if !found.isEmpty { return .found(entry, found) }
            } catch {
                return .badPattern
            }
        }
        return .nowhere(searched: seen.count)
    }
}
