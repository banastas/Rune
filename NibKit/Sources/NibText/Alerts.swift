// Notifications (PRD SY15, A8, V13): only for a conflict, or a file Nib can't save or sync, and
// only while Nib isn't frontmost (there the strip and the banner say it), with the default
// sound. Each said once while it lasts, per file, and again only once it has ended and comes
// back: a full disk retried every 15 s, or iCloud's storage every few minutes, is one
// notification, not one a retry. The words are the strip's and the banners', as sentences.

import Foundation

public enum Alerts {
    public enum Kind: String, Sendable, CaseIterable {
        /// Both versions between markers (§4.8 B).
        case conflict
        /// A save, the journal, or the Recovery folder couldn't be written (§4.9, 13).
        case saveFailed
        /// Deleted, by another app or on another Mac, or moved to this Mac's Trash (§4.8 E, §4.9, 8).
        case deleted
        /// iCloud Drive turned off, the file gone with it (§4.9, 11).
        case iCloudOff
        /// iCloud's storage full: saved here only (§4.9, 12).
        case storageFull
    }

    public struct Alert: Equatable, Sendable {
        public var kind: Kind
        public var title: String
        public var body: String

        public init(kind: Kind, title: String, body: String) {
            self.kind = kind
            self.title = title
            self.body = body
        }
    }

    /// "✕ CONFLICT WITH AIR · 1 PLACE · BOTH VERSIONS ARE IN THE TEXT".
    public static func conflict(_ name: String, with who: String, places: Int) -> Alert {
        Alert(kind: .conflict, title: "Conflict with \(who) in \(name)",
              // ⌘3 keeps both (it said "⌘1, ⌘2 or ⌘3 keeps one": the QA review's F8, 2026-10-07).
              body: places == 1 ? "In 1 place: both versions are in the text, between markers. In Nib, ⌘1 or ⌘2 in the block keeps one version, ⌘3 keeps both."
                                : "In \(places) places: both versions of each are in the text, between markers. In Nib, ⌘1 or ⌘2 in a block keeps one version, ⌘3 keeps both.")
    }

    /// This Mac's disk is full: the journal and the save both fail (§4.9, 13).
    public static func diskFull(_ name: String) -> Alert {
        Alert(kind: .saveFailed, title: "Couldn't save \(name)",
              body: "This Mac's disk is full. Your latest changes are only in memory: free some space, or copy them.")
    }

    /// A save that failed for another reason (`why`, the error in short): the text is in the journal.
    public static func saveFailed(_ name: String, why: String, toRecovery: Bool = false) -> Alert {
        Alert(kind: .saveFailed, title: toRecovery ? "Couldn't save \(name) to Nib's Recovery folder" : "Couldn't save \(name)",
              body: "\(sentence(why)) Your text is in Nib's recovery journal, and Nib keeps trying.")
    }

    /// The journal that couldn't be written: the latest typing is in memory only.
    public static func journalFailed(_ name: String, why: String) -> Alert {
        Alert(kind: .saveFailed, title: "Couldn't write Nib's recovery journal",
              body: "\(sentence(why)) Your latest typing in \(name) is only in memory, and Nib keeps trying.")
    }

    public static func deleted(_ name: String, trash: Bool) -> Alert {
        Alert(kind: .deleted, title: trash ? "\(name) was moved to the Trash" : "\(name) was deleted",
              body: "\(trash ? "Another app" : "Another app, or another Mac,") did it. Your text is still in Nib, and Restore puts the file back.")
    }

    public static func iCloudOff(_ name: String) -> Alert {
        Alert(kind: .iCloudOff, title: "iCloud Drive is off on this Mac",
              body: "\(name) went with it. Nib saves your text to its Recovery folder, and puts it back when iCloud Drive is on again.")
    }

    public static func storageFull(_ name: String) -> Alert {
        Alert(kind: .storageFull, title: "iCloud storage is full",
              body: "\(name) is saved on this Mac only, and won't reach your other Macs until there's room.")
    }

    /// An error's short words ("NO PERMISSION", as the strip has them) as the start of a sentence.
    static func sentence(_ text: String) -> String {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = plain.first else { return "" }
        let lower = plain.uppercased() == plain ? plain.lowercased() : plain
        let start = String(first).uppercased() + lower.dropFirst()
        return start.hasSuffix(".") ? start : start + "."
    }
}

/// Which problems have been said (SY15): per file, those going on now, and of them the ones a
/// notification went out for.
public struct AlertLedger: Sendable {
    private var ongoing: [String: Set<Alerts.Kind>] = [:]
    private var posted: [String: Set<Alerts.Kind>] = [:]

    public init() {}

    /// A problem began, or happened again while it lasts: true to post a notification. Not
    /// while Nib is frontmost, where the strip says it; and seen there, it isn't said later.
    public mutating func began(_ kind: Alerts.Kind, file: String, frontmost: Bool) -> Bool {
        guard ongoing[file, default: []].insert(kind).inserted else { return false }
        guard !frontmost else { return false }
        posted[file, default: []].insert(kind)
        return true
    }

    /// It's over: true if a notification went out for it, to take it out of Notification Center.
    public mutating func ended(_ kind: Alerts.Kind, file: String) -> Bool {
        guard ongoing[file]?.remove(kind) != nil else { return false }
        return posted[file]?.remove(kind) != nil
    }

    /// The file closed: all of it is over; the kinds a notification went out for.
    public mutating func closed(_ file: String) -> [Alerts.Kind] {
        let said = Alerts.Kind.allCases.filter { posted[file]?.contains($0) == true }
        ongoing[file] = nil
        posted[file] = nil
        return said
    }

    public func isOngoing(_ kind: Alerts.Kind, file: String) -> Bool { ongoing[file]?.contains(kind) == true }
}
