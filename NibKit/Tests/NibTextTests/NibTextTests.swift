// Round trips for the file formats nib must preserve (PRD ED5), Keep Both's
// conflict text (SY6, §4.7), and plain paste (PT1).

import Foundation
import Testing

@testable import NibText

@Suite struct TextFileTests {
    @Test func utf8LFRoundTrip() {
        let data = Data("one\ntwo\n".utf8)
        let (text, format) = TextFile.decode(data)
        #expect(text == "one\ntwo\n")
        #expect(format == FileFormat(encoding: .utf8, hasBOM: false, lineEnding: .lf))
        #expect(TextFile.encode(text, as: format) == data)
    }

    @Test func crlfIsEditedAsLFAndWrittenBack() {
        let data = Data("one\r\ntwo\r\n".utf8)
        let (text, format) = TextFile.decode(data)
        #expect(text == "one\ntwo\n")
        #expect(format.lineEnding == .crlf)
        #expect(TextFile.encode(text + "three\n", as: format) == Data("one\r\ntwo\r\nthree\r\n".utf8))
    }

    @Test func classicMacCR() {
        let (text, format) = TextFile.decode(Data("a\rb".utf8))
        #expect(text == "a\nb")
        #expect(format.lineEnding == .cr)
        #expect(TextFile.encode(text, as: format) == Data("a\rb".utf8))
    }

    @Test func noFinalNewlineStaysThatWay() {
        let data = Data("no newline".utf8)
        let (text, format) = TextFile.decode(data)
        #expect(TextFile.encode(text, as: format) == data)
    }

    @Test func utf8BOMIsKept() {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("héllo\n".utf8))
        let (text, format) = TextFile.decode(data)
        #expect(text == "héllo\n")
        #expect(format.hasBOM && format.encoding == .utf8)
        #expect(TextFile.encode(text, as: format) == data)
    }

    @Test func utf16LEWithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("hi\r\n".data(using: .utf16LittleEndian)!)
        let (text, format) = TextFile.decode(data)
        #expect(text == "hi\n")
        #expect(format.encoding == .utf16LE && format.lineEnding == .crlf)
        #expect(TextFile.encode(text, as: format) == data)
    }

    @Test func invalidUTF8FallsBackToLatin1() {
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])   // "café\n" in Latin-1
        let (text, format) = TextFile.decode(data)
        #expect(text == "café\n")
        #expect(format.encoding == .latin1)
        #expect(TextFile.encode(text, as: format) == data)
    }

    @Test func emptyFile() {
        let (text, format) = TextFile.decode(Data())
        #expect(text.isEmpty)
        #expect(format == .standard)
    }
}

@Suite struct ConflictTextTests {
    let air = "Air · 10:42", studio = "Studio · 10:41"

    @Test func keepsCommonLinesAndMarksTheDifference() {
        let base = "Hi Sam,\nthanks.\nWe can ship Friday.\nBill\n"
        let mine = ConflictText.Side(text: base.replacingOccurrences(of: "Friday", with: "Friday if QA signs off"), label: air)
        let theirs = ConflictText.Side(text: base.replacingOccurrences(of: "Friday", with: "Thursday"), label: studio)
        let merged = ConflictText.keepBoth(mine, theirs)
        #expect(merged == """
        Hi Sam,
        thanks.
        <<<<<<< Air · 10:42
        We can ship Friday if QA signs off.
        =======
        We can ship Thursday.
        >>>>>>> Studio · 10:41
        Bill

        """)
        #expect(ConflictText.hasMarkers(merged))
    }

    @Test func sameBytesOnEitherMac() {
        let a = ConflictText.Side(text: "x\none\n", label: air)
        let b = ConflictText.Side(text: "x\ntwo\n", label: studio)
        #expect(ConflictText.keepBoth(a, b) == ConflictText.keepBoth(b, a))
    }

    @Test func identicalSidesNeedNoMarkers() {
        let side = ConflictText.Side(text: "same\n", label: air)
        #expect(ConflictText.keepBoth(side, ConflictText.Side(text: "same\n", label: studio)) == "same\n")
    }

    @Test func appendOnOneSide() {
        let a = ConflictText.Side(text: "a\nb\n", label: air)
        let b = ConflictText.Side(text: "a\nb\nc\n", label: studio)
        let merged = ConflictText.keepBoth(a, b)
        #expect(merged.contains("a\nb\n<<<<<<< Air · 10:42\n=======\nc\n>>>>>>> Studio · 10:41"))
        #expect(merged.contains("c"))
    }
}

@Suite struct PasteTests {
    @Test func plainPasteNormalizesLineEndings() {
        #expect(PasteCleaner.plain("a\r\nb\rc") == "a\nb\nc")
    }

    @Test func cleanRemovesInvisibles() {
        let r = PasteCleaner.clean("zero\u{200B}width\u{00A0}space\u{FEFF}")
        #expect(r.text == "zerowidth space")
        #expect(r.invisibles == 2 && r.spaces == 1)
    }
}

/// Paste Clean and Clean Clipboard (PT3-PT4): what's removed, what's kept, and the counts
/// the confirmations show; Copy Block (SC5): the fenced code at the caret, or its paragraph.
@Suite struct CleanTextTests {
    @Test func invisiblesSpacesAndTrailing() {
        let r = PasteCleaner.clean("a\u{200B}b\u{FEFF}c\u{00AD}d\u{202E}e  \r\nnon\u{00A0}breaking\u{2009}thin\t\n")
        #expect(r.text == "abcde\nnon breaking thin\n")
        #expect(r.invisibles == 4 && r.spaces == 2 && r.trailing == 2 && r.quotes == 0)
        #expect(r.facts == ["4 INVISIBLES REMOVED", "2 SPACES MADE PLAIN", "2 LINES TRIMMED"])
    }

    @Test func joinersKeptWhereTheyDoTheirJob() {
        let family = "👨\u{200D}👩\u{200D}👧"
        #expect(PasteCleaner.clean(family).text == family)                      // an emoji family stays one
        #expect(PasteCleaner.clean("می\u{200C}خواهم").text == "می\u{200C}خواهم")  // Persian's non-joiner stays
        #expect(PasteCleaner.clean("ab\u{200D}cd").text == "abcd")              // between ASCII: junk
    }

    @Test func quotesOnlyWhenAsked() {
        let text = "“Nib’s” – fine — really…"
        #expect(PasteCleaner.clean(text).text == text)
        let r = PasteCleaner.clean(text, options: .init(straightenQuotes: true))
        #expect(r.text == "\"Nib's\" - fine -- really..." && r.quotes == 6)
    }

    @Test func nothingToClean() {
        let r = PasteCleaner.clean("plain text\nas it should be")
        #expect(!r.changed && r.facts == ["NOTHING TO CLEAN"])
    }

    @Test func copyBlockFindsTheFencedCode() {
        let text = "Notes\n\n```bash\nssh me@box\nrsync -av ./dist/ box:\n```\n\nA paragraph\nthat wraps.\n\nLast"
        let ns = text as NSString
        func block(at word: String) -> (String, TextBlocks.Kind)? {
            TextBlocks.block(at: ns.range(of: word).location, in: text).map { (ns.substring(with: $0.range), $0.kind) }
        }
        #expect(block(at: "rsync")! == ("ssh me@box\nrsync -av ./dist/ box:", .code))
        #expect(block(at: "```bash")! == ("ssh me@box\nrsync -av ./dist/ box:", .code))   // on the fence
        #expect(block(at: "wraps")! == ("A paragraph\nthat wraps.", .paragraph))
        #expect(block(at: "Last")! == ("Last", .paragraph))
        #expect(TextBlocks.block(at: 6, in: text) == nil)   // a blank line: nothing
        #expect(TextBlocks.block(at: 3, in: "```\n```\n") == nil)   // an empty block
    }
}
