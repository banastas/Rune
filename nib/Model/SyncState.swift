// What the status strip says about the open file (PRD §4.5): a glyph and words,
// never color alone (V4), and a red tag only when a decision or a fix is needed (V3).

import Foundation

enum SyncState: Equatable {
    case opening
    /// Evicted by Optimize Mac Storage; downloading before it can be read.
    case notDownloaded
    /// Not on this Mac and offline (or iCloud slow to bring it): the copy Nib saw last, from this
    /// time, typing allowed, merged when the file comes (§4.8 F).
    case offline(Date)
    /// Typed in the last second: in the journal, not yet in the file.
    case editing
    /// In the file on this Mac; iCloud doesn't have this version yet.
    case saved(Date)
    /// Saved, in a file outside iCloud Drive: there's nothing more to wait for (§4.5's local file;
    /// the QA review's F6: it read "= SAVED LOCALLY" for good, and the menu bar marched).
    case savedHere(Date)
    case uploading(Date)
    /// An untitled buffer (ED3): in Nib's own folder on this Mac, never synced.
    case local(Date)
    /// iCloud has this exact version (the upload call returned it, or iCloud reported it).
    case synced(Date)
    /// Nothing wrong, just waiting on something outside nib (W4, L6: never red).
    case waiting(String)
    case problem(String)

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// "10:42", or "SEP 30 10:42" for another day.
    static func moment(_ time: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(time) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: time).uppercased()
    }

    /// The strip's words, HUD grammar (W5).
    var line: String {
        switch self {
        case .opening: "· OPENING"
        case .notDownloaded: "◐ NOT ON THIS MAC · DOWNLOADING"
        case .offline(let time): "◐ OFFLINE · SHOWING THE COPY FROM \(Self.moment(time)) · EDITS MERGE WHEN ICLOUD RETURNS"
        case .editing: "· EDITING"
        case .saved(let time): "= SAVED LOCALLY · \(Self.clock.string(from: time))"
        case .savedHere(let time): "✓ SAVED · \(Self.clock.string(from: time))"
        case .uploading(let time): "▲ UPLOADING · SAVED \(Self.clock.string(from: time))"
        case .local(let time): "= ON THIS MAC ONLY · \(Self.clock.string(from: time))"
        case .synced(let time): "✓ SYNCED · \(Self.clock.string(from: time))"
        case .waiting(let why): "‖ \(why)"
        case .problem(let why): why
        }
    }

    var isProblem: Bool {
        if case .problem = self { true } else { false }
    }

    var isSynced: Bool {
        if case .synced = self { true } else { false }
    }

    /// The muted-red tag in front of the words, when there is one.
    var tag: String? {
        switch self {
        case .problem: "✕"
        default: nil
        }
    }

    var isDim: Bool {
        switch self {
        case .opening, .editing, .waiting: true
        default: false
        }
    }

    /// For VoiceOver (AX1).
    var spoken: String {
        switch self {
        case .opening: "Opening"
        case .notDownloaded: "Not on this Mac, downloading"
        case .offline(let time): "Offline, showing the copy from \(Self.moment(time).lowercased()); edits merge when iCloud returns"
        case .editing: "Editing"
        case .saved(let time): "Saved on this Mac at \(Self.clock.string(from: time)), not in iCloud yet"
        case .savedHere(let time): "Saved at \(Self.clock.string(from: time))"
        case .uploading: "Uploading to iCloud"
        case .local(let time): "Kept on this Mac only, at \(Self.clock.string(from: time))"
        case .synced(let time): "Synced at \(Self.clock.string(from: time))"
        case .waiting(let why): "Waiting: \(why.lowercased())"
        case .problem(let why): "Problem: \(why.lowercased())"
        }
    }
}
