// What the status strip says about the open file (PRD §4.5): a glyph and words,
// never color alone (V4), and a red tag only when a decision or a fix is needed (V3).

import Foundation
import NibText

enum SyncState: Equatable {
    case opening
    /// Evicted by Optimize Mac Storage; downloading before it can be read.
    case notDownloaded
    /// Not on this Mac and offline, or online with iCloud slow to bring it (`slow`): the copy Nib
    /// saw last, from this time, typing allowed, merged when the file comes (§4.8 F). Online, it
    /// said "OFFLINE" too (the QA review's F15).
    case offline(Date, slow: Bool)
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
        formatter.locale = Locale(identifier: "en_US_POSIX")   // 24-hour whatever the Mac's 12-hour setting (W5; F65)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// "10:42:07" today, "SEP 30 10:42" for another day: a time from yesterday read as today's
    /// (the QA review's F65), and a file opened shows its version's own time (F13).
    static func stamp(_ time: Date) -> String {
        Calendar.current.isDateInToday(time) ? clock.string(from: time) : moment(time)
    }

    /// "10:42", or "SEP 30 10:42" for another day.
    static func moment(_ time: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(time) ? "HH:mm" : "MMM d HH:mm"
        return formatter.string(from: time).uppercased()
    }

    /// The strip's words, HUD grammar (W5).
    var line: String {
        switch self {
        case .opening: "· OPENING"
        case .notDownloaded: "◐ NOT ON THIS MAC · DOWNLOADING"
        case .offline(let time, let slow): slow ? "◐ NOT HERE YET · ICLOUD IS SLOW TO BRING IT · SHOWING THE COPY FROM \(Self.moment(time)) · EDITS MERGE WHEN IT COMES"
                                                : "◐ OFFLINE · SHOWING THE COPY FROM \(Self.moment(time)) · EDITS MERGE WHEN ICLOUD RETURNS"
        case .editing: "· EDITING"
        case .saved(let time): "= SAVED LOCALLY · \(Self.stamp(time))"
        case .savedHere(let time): "✓ SAVED · \(Self.stamp(time))"
        case .uploading(let time): "▲ UPLOADING · SAVED \(Self.stamp(time))"
        case .local(let time): "= ON THIS MAC ONLY · \(Self.stamp(time))"
        case .synced(let time): "✓ SYNCED · \(Self.stamp(time))"
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

    /// "10:42:07", or "Sep 30 10:42" for another day, for VoiceOver.
    static func spokenStamp(_ time: Date) -> String {
        guard !Calendar.current.isDateInToday(time) else { return clock.string(from: time) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: time)
    }

    /// A spoken line mid-sentence: its first letter lowered, the rest as it is.
    static func midSentence(_ said: String) -> String {
        guard let first = said.first else { return said }
        return first.lowercased() + said.dropFirst()
    }

    /// For VoiceOver (AX1).
    var spoken: String {
        switch self {
        case .opening: "Opening"
        case .notDownloaded: "Not on this Mac, downloading"
        case .offline(let time, let slow): slow ? "Not here yet: iCloud is slow to bring it. Showing the copy from \(Self.spokenStamp(time)); edits merge when it comes"
                                                : "Offline, showing the copy from \(Self.spokenStamp(time)); edits merge when iCloud returns"
        case .editing: "Editing"
        case .saved(let time): "Saved on this Mac at \(Self.spokenStamp(time)), not in iCloud yet"
        case .savedHere(let time): "Saved at \(Self.spokenStamp(time))"
        case .uploading: "Uploading to iCloud"
        case .local(let time): "Kept on this Mac only, at \(Self.spokenStamp(time))"
        case .synced(let time): "Synced at \(Self.spokenStamp(time))"
        // As sentences, names keeping their capitals ("icloud drive is off on this mac": F17).
        case .waiting(let why): "Waiting: \(Spoken.sentence(why))"
        case .problem(let why): "Problem: \(Spoken.sentence(why))"
        }
    }
}
