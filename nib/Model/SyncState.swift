// What the status strip says about the open file (PRD §4.5): a glyph and words,
// never color alone (V4), and a red tag only when a decision or a fix is needed (V3).

import Foundation

enum SyncState: Equatable {
    case opening
    /// Evicted by Optimize Mac Storage; downloading before it can be read.
    case notDownloaded
    /// Typed in the last second: in the journal, not yet in the file.
    case editing
    /// In the file on this Mac; iCloud doesn't have this version yet.
    case saved(Date)
    case uploading(Date)
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

    /// The strip's words, HUD grammar (W5).
    var line: String {
        switch self {
        case .opening: "· OPENING"
        case .notDownloaded: "◐ NOT ON THIS MAC · DOWNLOADING"
        case .editing: "· EDITING"
        case .saved(let time): "= SAVED LOCALLY · \(Self.clock.string(from: time))"
        case .uploading(let time): "▲ UPLOADING · SAVED \(Self.clock.string(from: time))"
        case .synced(let time): "✓ SYNCED · \(Self.clock.string(from: time))"
        case .waiting(let why): "‖ \(why)"
        case .problem(let why): why
        }
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
        case .editing: "Editing"
        case .saved(let time): "Saved on this Mac at \(Self.clock.string(from: time)), not in iCloud yet"
        case .uploading: "Uploading to iCloud"
        case .synced(let time): "Synced at \(Self.clock.string(from: time))"
        case .waiting(let why): "Waiting: \(why.lowercased())"
        case .problem(let why): "Problem: \(why.lowercased())"
        }
    }
}
