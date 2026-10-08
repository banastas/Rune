// The headings list (PRD SC7, ⌘R): what's a Markdown heading and what isn't.

import Foundation
import Testing

@testable import NibText

@Suite struct HeadingsTests {
    func titles(_ text: String) -> [String] {
        Headings.markdown(in: text as NSString).map { "\(String(repeating: "#", count: $0.level)) \($0.title) @\($0.line)" }
    }

    @Test func atxHeadings() {
        let text = "# One\n\nSome text.\n\n## Two ##\n   ### Three, indented\n#### Four #not closing\n##### \n###### Six\n####### Seven\n#hashtag\n"
        #expect(titles(text) == ["# One @1", "## Two @5", "### Three, indented @6", "#### Four #not closing @7", "###### Six @9"])
    }

    @Test func setextHeadings() {
        let text = "Title\n=====\n\nA paragraph\nover two lines\n---\n\n---\n\nAfter a rule\n"
        // The second --- follows a blank line: a rule, not a heading.
        #expect(titles(text) == ["# Title @1", "## A paragraph over two lines @4"])
    }

    @Test func notInsideCodeCommentsOrFrontMatter() {
        let text = """
        ---
        title: Notes
        # not a heading
        ---
        # Real

        ```bash
        # a comment in code
        ```

        ~~~~
        # still code
        ```
        # still code, the fence is ~~~~
        ~~~~

            # indented: code

        <!--
        # commented out
        -->
        ## After the comment
        """
        #expect(titles(text) == ["# Real @5", "## After the comment @22"])
    }

    @Test func listsQuotesAndRulesAreNotSetextTitles() {
        let text = "- an item\n---\n\n> a quote\n===\n\n| a | b |\n---\n\nText\n- - -\n"
        #expect(titles(text).isEmpty)
    }

    @Test func aNumberedListIsNotAHeadingEither() {
        let text = "1. First | Ep. 1\n2. Second | Ep. 2\n\n## The list's heading\n"
        #expect(titles(text) == ["## The list's heading @4"])
    }

    @Test func locationsAreLineStartsInUTF16() {
        let text = "é😀 intro\n\n# Heading\n" as NSString
        let heading = Headings.markdown(in: text).first
        #expect(heading?.location == text.range(of: "# Heading").location && heading?.line == 3)
    }

    @Test func aBigTextQuickly() {
        var text = "# Notes\n"
        for n in 1...35_000 { text += n % 100 == 0 ? "## Section \(n)\n" : "Line \(n): see https://example.com/\(n) and the config.json file.\n" }
        let started = Date()
        let found = Headings.markdown(in: text as NSString)
        let seconds = Date().timeIntervalSince(started)
        #expect(found.count == 351)
        #expect(seconds < 2, "\(seconds) s (Debug)")
    }
}
