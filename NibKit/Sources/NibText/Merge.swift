// Three-way merge (PRD §4.7): diff3 over lines, from the version both sides started from.
// A stretch where both sides changed the same lines is retried over words, because a
// scratch file is mostly prose with long lines; what still overlaps goes between conflict
// markers, as Keep Both writes them. Deterministic (SY10): sides are ordered by label,
// never "mine first", so two Macs merging the same pair write the same bytes.

public enum Merge {
    public struct Result: Sendable, Equatable {
        /// The merged text. Overlapping edits are between conflict markers.
        public var text: String
        /// Blocks between conflict markers.
        public var conflicts: Int
        /// Stretches taken from one side only, for each side in the order they were passed.
        public var changesFromFirst: Int
        public var changesFromSecond: Int
        /// Some stretch merged only word by word ("merged within a line").
        public var withinLine: Bool

        public var isClean: Bool { conflicts == 0 }
    }

    /// Merges `a` and `b`, both made from `base`.
    public static func threeWay(base: String, _ a: ConflictText.Side, _ b: ConflictText.Side) -> Result {
        if a.text == b.text { return Result(text: a.text, conflicts: 0, changesFromFirst: 0, changesFromSecond: 0, withinLine: false) }
        let swapped = b.label < a.label
        let (first, second) = swapped ? (b, a) : (a, b)
        let o = ConflictText.lines(base), x = ConflictText.lines(first.text), y = ConflictText.lines(second.text)
        var out: [Substring] = []
        var conflicts = 0, fromX = 0, fromY = 0, withinLine = false
        func block<C: Collection<Substring>>(_ x: C, _ y: C) {
            out.append("<<<<<<< \(first.label)")
            out += x
            out.append("=======")
            out += y
            out.append(">>>>>>> \(second.label)")
            conflicts += 1
        }
        for chunk in chunks(base: o, x, y) {
            switch chunk {
            case .same(let lines):
                out += lines
            case .first(let lines):
                out += lines; fromX += 1
            case .second(let lines):
                out += lines; fromY += 1
            case .both(let lines):
                out += lines
            case .overlap(let o, let x, let y):
                if let words = mergeWords(base: o.joined(separator: "\n"), x.joined(separator: "\n"), y.joined(separator: "\n")) {
                    out += words; fromX += 1; fromY += 1; withinLine = true
                } else if o.count > 1, x.count == o.count, y.count == o.count {
                    // Edited in place on both sides, as many lines each: line by line, so only
                    // the lines both changed differently go between markers. A line either side
                    // changed is never dropped: it's taken, or it's in a block.
                    var pending: (x: [Substring], y: [Substring]) = ([], [])
                    for ((l, p), q) in zip(zip(o, x), y) {
                        var merged: [Substring]?
                        if p == l { merged = [q]; if q != l { fromY += 1 } }
                        else if q == l { merged = [p]; fromX += 1 }
                        else if p == q { merged = [p] }
                        else if let words = mergeWords(base: String(l), String(p), String(q)) {
                            merged = words; fromX += 1; fromY += 1; withinLine = true
                        }
                        if let merged {
                            if !pending.x.isEmpty { block(pending.x, pending.y); pending = ([], []) }
                            out += merged
                        } else {
                            pending.x.append(p); pending.y.append(q)
                        }
                    }
                    if !pending.x.isEmpty { block(pending.x, pending.y) }
                } else {
                    block(x, y)
                }
            }
        }
        return Result(text: out.joined(separator: "\n"), conflicts: conflicts,
                      changesFromFirst: swapped ? fromY : fromX, changesFromSecond: swapped ? fromX : fromY,
                      withinLine: withinLine)
    }

    /// A stretch where both sides changed the same lines, merged over words: nil if the
    /// words overlap too.
    static func mergeWords(base: String, _ x: String, _ y: String) -> [Substring]? {
        let o = words(base), a = words(x), b = words(y)
        var out = ""
        for chunk in chunks(base: o, a, b) {
            switch chunk {
            case .same(let w), .first(let w), .second(let w), .both(let w): out += w.joined()
            case .overlap: return nil
            }
        }
        return out.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Words, runs of spaces and tabs, and line breaks, so joining them gives the text back.
    static func words(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        func kind(_ c: Character) -> Int { c == "\n" ? 0 : (c == " " || c == "\t") ? 1 : 2 }
        var index = text.startIndex
        while index < text.endIndex {
            let k = kind(text[index])
            var next = text.index(after: index)
            if k != 0 { while next < text.endIndex, kind(text[next]) == k { next = text.index(after: next) } }
            result.append(text[start..<next])
            start = next
            index = next
        }
        return result
    }

    // MARK: diff3

    enum Chunk<T: Hashable> {
        /// Unchanged on both sides.
        case same(ArraySlice<T>)
        /// Changed on one side only: that side's version.
        case first(ArraySlice<T>)
        case second(ArraySlice<T>)
        /// Changed the same way on both.
        case both(ArraySlice<T>)
        /// Changed differently on both: base, first, second.
        case overlap(ArraySlice<T>, ArraySlice<T>, ArraySlice<T>)
    }

    /// The classic diff3 walk: a base element kept by both sides is stable; between stable
    /// runs, each side's stretch is compared with the base's.
    static func chunks<T: Hashable>(base o: [T], _ a: [T], _ b: [T]) -> [Chunk<T>] {
        let ma = matches(o, a), mb = matches(o, b)
        var result: [Chunk<T>] = []
        var i = 0, ja = 0, jb = 0
        while i < o.count || ja < a.count || jb < b.count {
            let stableStart = i
            while i < o.count, ma[i] == ja, mb[i] == jb { i += 1; ja += 1; jb += 1 }
            if i > stableStart { result.append(.same(o[stableStart..<i])) }
            guard i < o.count || ja < a.count || jb < b.count else { break }
            var k = i
            while k < o.count, ma[k] == nil || mb[k] == nil { k += 1 }
            let ea = k < o.count ? ma[k]! : a.count, eb = k < o.count ? mb[k]! : b.count
            let base = o[i..<k], x = a[ja..<ea], y = b[jb..<eb]
            if x.elementsEqual(base) { result.append(.second(y)) }
            else if y.elementsEqual(base) { result.append(.first(x)) }
            else if x.elementsEqual(y) { result.append(.both(x)) }
            else if base.isEmpty, !x.isEmpty, !y.isEmpty, let longer = extends(x, y) {
                // Both added text at the same place and one addition carries the other's:
                // the longer loses nothing.
                result.append(longer == 0 ? .first(x) : .second(y))
            } else {
                result.append(.overlap(base, x, y))
            }
            i = k; ja = ea; jb = eb
        }
        return result
    }

    /// 0 if `x` starts or ends with all of `y`, 1 if `y` starts or ends with all of `x`.
    static func extends<T: Equatable>(_ x: ArraySlice<T>, _ y: ArraySlice<T>) -> Int? {
        func carries(_ long: ArraySlice<T>, _ short: ArraySlice<T>) -> Bool {
            long.count > short.count && (long.prefix(short.count).elementsEqual(short) || long.suffix(short.count).elementsEqual(short))
        }
        if carries(x, y) { return 0 }
        if carries(y, x) { return 1 }
        return nil
    }

    /// For each base element, its index in `new` if `new` kept it.
    static func matches<T: Hashable>(_ base: [T], _ new: [T]) -> [Int?] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: base) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: base.count)
        var j = 0
        for i in base.indices where !removed.contains(i) {
            while inserted.contains(j) { j += 1 }
            result[i] = j
            j += 1
        }
        return result
    }
}
