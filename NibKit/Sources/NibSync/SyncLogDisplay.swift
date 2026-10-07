// How the Sync Log window shows a line (PRD SY13, A13, V4): a glyph and a word for each
// event, never color alone, the one muted red only for what went wrong (V3), and which of
// the window's filters it belongs to. Search looks at the file, the event, the device, the
// detail and the SHA-256 (from its start).

import Foundation

extension SyncEvent {
    public enum Category: String, CaseIterable, Sendable, Identifiable {
        case all = "All"
        case saves = "Saves"
        case arrivals = "Arrivals"
        case problems = "Problems"
        public var id: Self { self }

        /// What each filter shows, for its tooltip.
        public var help: String {
            switch self {
            case .all: "Every event"
            case .saves: "Opening, saving, uploading, and holding and handing back files"
            case .arrivals: "Versions from other Macs and apps, merges, recoveries and reverts"
            case .problems: "Conflicts, uploads iCloud refused or didn't answer, and anything that failed"
            }
        }
    }

    /// The file's name ("scratch.md").
    public var fileName: String { (path as NSString).lastPathComponent }

    /// Something went wrong: a problem, a failed step (the muted red, V3).
    public var failed: Bool {
        if event == "problem" { return true }
        guard let detail = detail?.lowercased() else { return false }
        return detail.hasPrefix("failed") || detail.contains(": failed") || detail.hasPrefix("couldn't") || detail.contains("running unheld")
            || detail.hasPrefix("still failing")
    }

    /// A conflict, or a step iCloud refused or didn't answer: in "Conflicts and problems".
    public var needsLook: Bool {
        if failed || event == "conflict" { return true }
        guard let detail = detail?.lowercased() else { return false }
        return detail.hasPrefix("refused") || detail.contains("no answer") || detail.hasPrefix("not held yet")
    }

    public var category: Category {
        switch event {
        case "open", "save", "upload", "pause", "resume", "quit": .saves
        default: .arrivals
        }
    }

    public func belongs(to filter: Category) -> Bool {
        switch filter {
        case .all: true
        case .problems: needsLook
        default: category == filter && !failed   // what went wrong is under Conflicts and problems
        }
    }

    /// The strip's glyphs (V4): = saved, ▲ uploaded, ▼ came in, ✓ merged or resolved,
    /// ‖ waiting on iCloud, ✕ went wrong, · the rest.
    public var glyph: String {
        if failed || event == "conflict" { return "✕" }
        if needsLook { return "‖" }
        switch event {
        case "save": return "="
        case "upload": return "▲"
        case "fetch", "reload", "update", "refresh", "announce", "duplicate", "conflict version": return "▼"
        case "merge", "resolve", "revert", "recover": return "✓"
        default: return "·"
        }
    }

    /// The event in a word or two, sentence case (W5).
    public var word: String {
        switch event {
        case "open": return "Opened"
        case "save": return "Saved"
        case "upload":
            if detail?.hasPrefix("refused") == true { return "Upload refused" }
            if failed { return "Upload failed" }
            if detail?.contains("no answer") == true { return "Upload unanswered" }
            return "Uploaded"
        case "fetch": return "Fetched"
        case "reload": return "Reloaded"
        case "update": return "Updated"
        case "refresh": return "Refreshed"
        case "announce": return "Announced"
        case "merge": return "Merged"
        case "merge view": return "Merge view"
        case "conflict": return "Conflict"
        case "conflict version": return "Conflict version"
        case "duplicate": return "Duplicate"
        case "resolve": return "Resolved"
        case "revert": return "Reverted"
        case "recover": return "Recovered"
        case "pause":
            // A hold not made says so first ("not held yet: …", "not offered: …", "failed, …", "still
            // failing after 3 tries: …"), and a lost one begins "the hold didn't last"; every other
            // line is a hold made ("after its upload (2.6 s)", "held on try 2", "already paused, by
            // this Mac: holding it as it is"), which read "Not held" until 2026-10-06.
            guard let detail else { return "Held" }
            if detail.hasPrefix("the hold didn't last") { return "Hold lost" }
            return ["not ", "failed", "still failing"].contains { detail.hasPrefix($0) } ? "Not held" : "Held"
        case "resume": return "Handed back"
        case "quit": return "Closed"
        case "problem": return "Problem"
        default: return event.prefix(1).uppercased() + event.dropFirst()
        }
    }

    /// Search: every word of the query in the file, the event, the device or the detail, or
    /// the query as the start of the SHA-256.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if let sha = sha256?.lowercased(), query.count >= 4, sha.hasPrefix(query) { return true }
        let haystack = [path, event, word, device, detail ?? ""].joined(separator: " ").lowercased()
        return query.split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
