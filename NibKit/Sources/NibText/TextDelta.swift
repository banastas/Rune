// The smallest single change from one text to another: what they share at the start and at
// the end stays, the rest is replaced (PRD §6.5: a reload of the scratch file at 2.4 MB ≤ 100
// ms). A version from another app or another Mac usually differs in a few lines, and replacing
// only those keeps TextKit's layout, the line index and the undo step small, where replacing
// the whole text redid all of them (303 ms at 2.4 MB, Debug). Offsets are UTF-16, as NSString's;
// compared 64K code units at a time with memcmp.

import Foundation

public enum TextDelta {
    public struct Change: Equatable, Sendable {
        /// The range in the old text to replace.
        public var range: NSRange
        /// What goes there.
        public var replacement: String
    }

    /// Whether two texts are the same, UTF-16 unit for unit. Swift's == compares as Unicode, a
    /// character at a time when one side is bridged from a text view's string: 78 ms at 2.4 MB, on
    /// the main thread, in every reload (2026-09-30). This is under a millisecond, and exact as a
    /// file is: a precomposed é isn't a decomposed one.
    public static func same(_ a: NSString, _ b: NSString) -> Bool {
        a.length == b.length && change(from: a, to: b) == nil
    }

    /// The change that turns `old` into `new`, or nil when they're the same.
    public static func change(from old: NSString, to new: NSString) -> Change? {
        let oldLength = old.length, newLength = new.length
        let shortest = min(oldLength, newLength)
        let chunk = 65_536
        var a = [unichar](repeating: 0, count: chunk), b = [unichar](repeating: 0, count: chunk)

        /// How many code units match, comparing `count` from `start` in each (or back from the end).
        func matching(_ count: Int, fromEnd: Bool, done: Int) -> Int {
            let oldStart = fromEnd ? oldLength - done - count : done
            let newStart = fromEnd ? newLength - done - count : done
            return a.withUnsafeMutableBufferPointer { x in
                b.withUnsafeMutableBufferPointer { y in
                    old.getCharacters(x.baseAddress!, range: NSRange(location: oldStart, length: count))
                    new.getCharacters(y.baseAddress!, range: NSRange(location: newStart, length: count))
                    if memcmp(x.baseAddress!, y.baseAddress!, count * MemoryLayout<unichar>.size) == 0 { return count }
                    // Where they part, one code unit at a time inside this chunk.
                    if fromEnd {
                        var n = 0
                        while n < count, x[count - 1 - n] == y[count - 1 - n] { n += 1 }
                        return n
                    } else {
                        var n = 0
                        while n < count, x[n] == y[n] { n += 1 }
                        return n
                    }
                }
            }
        }

        var prefix = 0
        while prefix < shortest {
            let count = min(chunk, shortest - prefix)
            let same = matching(count, fromEnd: false, done: prefix)
            prefix += same
            if same < count { break }
        }
        if prefix == oldLength, prefix == newLength { return nil }
        var suffix = 0
        let room = shortest - prefix   // the end can't reach into what the start already took
        while suffix < room {
            let count = min(chunk, room - suffix)
            let same = matching(count, fromEnd: true, done: suffix)
            suffix += same
            if same < count { break }
        }
        // Not inside a surrogate pair: a change starts and ends on whole characters.
        if prefix > 0, prefix < oldLength, UTF16.isTrailSurrogate(old.character(at: prefix)) { prefix -= 1 }
        if suffix > 0, oldLength - suffix > prefix, UTF16.isTrailSurrogate(old.character(at: oldLength - suffix)) { suffix -= 1 }
        let range = NSRange(location: prefix, length: oldLength - suffix - prefix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - suffix - prefix))
        return Change(range: range, replacement: replacement)
    }
}
