// Undo Selection and Redo Selection (PRD ED8, ⌘U and ⇧⌘U): the carets as they were before each
// change to them, taken back one change at a time and put back again, as VS Code's cursor undo
// does. Sublime's soft undo steps back through edits too; here ⌘Z does those. A step is good
// only for the text it was made in, so an edit starts the steps over.

import Foundation

public struct CaretHistory: Sendable {
    /// The carets before each change, the latest last; and the ones Undo Selection took back.
    public private(set) var back: [Carets] = []
    public private(set) var forward: [Carets] = []
    /// The carets as they are, as last told.
    public private(set) var current: Carets?

    /// At most this many steps, and this many carets in them all (Find All makes thousands).
    public static let mostSteps = 50
    public static let mostCarets = 20_000

    public init() {}

    /// The carets changed (a key, a click, a command): the ones before are a step back, and
    /// what Undo Selection took back can't be put back any more.
    public mutating func changed(to carets: Carets) {
        defer { current = carets }
        guard let before = current, !Self.same(before, carets) else { return }
        back.append(before)
        forward.removeAll()
        while back.count > Self.mostSteps || (back.count > 1 && back.reduce(0, { $0 + $1.count }) > Self.mostCarets) {
            back.removeFirst()
        }
    }

    /// The text changed: the steps were for the text as it was.
    public mutating func textChanged(carets: Carets) {
        back.removeAll()
        forward.removeAll()
        current = carets
    }

    /// Undo Selection: the carets before the last change, or nil when there's none.
    public mutating func undo() -> Carets? {
        guard let now = current, let previous = back.popLast() else { return nil }
        forward.append(now)
        current = previous
        return previous
    }

    /// Redo Selection: the carets Undo Selection last took back, or nil.
    public mutating func redo() -> Carets? {
        guard let now = current, let next = forward.popLast() else { return nil }
        back.append(now)
        current = next
        return next
    }

    /// The same carets for this: the same places and the same primary (not the ↑↓ goal).
    static func same(_ a: Carets, _ b: Carets) -> Bool { a.ranges == b.ranges && a.primary == b.primary }
}
