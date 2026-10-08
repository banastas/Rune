// Where each line starts (PRD ED6, §6.5): the gutter's numbers and the strip's LN, COL, kept
// current edit by edit, so neither counts lines from the top of a 2.4 MB file. Offsets are
// UTF-16 units, as NSString's; lines are 1-based and end at "\n".

import Foundation

public struct LineIndex: Sendable, Equatable {
    /// The offset each line starts at: 0, then one past each "\n".
    public private(set) var starts: [Int] = [0]

    public init() {}

    public init(_ text: NSString) {
        starts = [0] + Self.newlines(in: text, range: NSRange(location: 0, length: text.length)).map { $0 + 1 }
    }

    public var lineCount: Int { starts.count }

    /// The line (1-based) an offset is on; an offset past the end is on the last line.
    public func line(at offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return max(1, low)
    }

    /// Where a line (1-based) starts; the end of the text for a line past the last.
    public func start(ofLine line: Int) -> Int? {
        starts.indices.contains(line - 1) ? starts[line - 1] : nil
    }

    /// After an edit: `edited` is the changed range in the new text, `delta` the change in
    /// length. Only the edited characters are looked at; the lines after it move by `delta`.
    public mutating func update(_ text: NSString, edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        // Lines starting inside the replaced text (their "\n" was in it) go; the rest move.
        var head = starts.prefix { $0 <= edited.location }
        let tail = starts.drop { $0 <= oldEnd }
        head.append(contentsOf: Self.newlines(in: text, range: edited).map { $0 + 1 })
        head.append(contentsOf: tail.map { $0 + delta })
        starts = Array(head)
    }

    /// Every "\n" in `range`, by NSString's own search.
    static func newlines(in text: NSString, range: NSRange) -> [Int] {
        var found: [Int] = []
        var from = range.location
        let end = NSMaxRange(range)
        while from < end {
            let hit = text.range(of: "\n", options: .literal, range: NSRange(location: from, length: end - from))
            guard hit.location != NSNotFound else { break }
            found.append(hit.location)
            from = hit.location + 1
        }
        return found
    }
}
