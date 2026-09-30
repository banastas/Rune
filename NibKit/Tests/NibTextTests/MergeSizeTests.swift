// The three-way merge at the scratch file's size (PRD §6.5: 2.4 MB; merged ≤ 100 ms): an
// edit near the top on one side, one at the end on the other, as `perf` merges them.

import Foundation
import Testing

@testable import NibText

@Suite struct MergeSizeTests {
    @Test func scratchSized() throws {
        var md = "# Scratch-sized\n", m = 0
        while md.utf8.count < 2_400_000 {
            m += 1
            md += m % 50 == 0 ? "## Notes for \(m)\n" : m % 3 == 0 ? "- item \(m) with `code` and **bold** text\n" : "Line \(m): see https://example.com/\(m) and the config.json file.\n"
        }
        let near = (md as NSString).range(of: "Line 31:").location   // (30 is an item line: "Line 30:" isn't there)
        try #require(near != NSNotFound)
        let ours = (md as NSString).replacingCharacters(in: NSRange(location: near, length: 0), with: "ours\n")
        let theirs = md + "theirs\n"
        let start = Date()
        let merged = Merge.threeWay(base: md, .init(text: ours, label: "Air · 10:00"), .init(text: theirs, label: "Mini · 10:00"))
        let seconds = Date().timeIntervalSince(start)
        print("merged 2.4 MB in \(Int(seconds * 1000)) ms")
        #expect(merged.text.contains("ours\n") && merged.text.hasSuffix("theirs\n"))
    }
}
