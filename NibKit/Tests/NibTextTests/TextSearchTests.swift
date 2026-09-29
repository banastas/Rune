// Find and replace (ED7): plain, case, whole word, regular expressions with $1, within a
// selection, a bad pattern said plainly, and going from match to match with wrapping.

import Foundation
import Testing

@testable import NibText

@Suite struct TextSearchTests {
    let text = "Deploy to seedbox.\ndeploy again; redeploy later.\nDEPLOY!"

    func words(_ ranges: [NSRange]) -> [String] { ranges.map { (text as NSString).substring(with: $0) } }

    @Test func plainAndCase() throws {
        #expect(try words(TextSearch.matches(of: "deploy", in: text, options: .init())) == ["Deploy", "deploy", "deploy", "DEPLOY"])
        #expect(try words(TextSearch.matches(of: "deploy", in: text, options: .init(matchCase: true))) == ["deploy", "deploy"])
        // A plain query is plain: "." and "(" are just characters.
        #expect(try TextSearch.matches(of: "box.", in: text, options: .init()).count == 1)
        #expect(try TextSearch.matches(of: "(", in: text, options: .init()).isEmpty)
    }

    @Test func wholeWord() throws {
        #expect(try words(TextSearch.matches(of: "deploy", in: text, options: .init(wholeWord: true))) == ["Deploy", "deploy", "DEPLOY"])
    }

    @Test func regularExpressions() throws {
        #expect(try words(TextSearch.matches(of: "^\\w+", in: text, options: .init(regex: true))) == ["Deploy", "deploy", "DEPLOY"])
        #expect(try words(TextSearch.matches(of: "re(deploy)", in: text, options: .init(regex: true))) == ["redeploy"])
        #expect(try TextSearch.matches(of: "x*", in: "abc", options: .init(regex: true)).isEmpty)   // empty matches left out
        #expect(throws: TextSearch.Failure.badPattern("(Unclosed")) { try TextSearch.matches(of: "(Unclosed", in: text, options: .init(regex: true, wholeWord: true)) }
        #expect(TextSearch.Failure.badPattern("v1\\.(").description == "NOT A REGULAR EXPRESSION · “v1\\.(”")   // as typed: case matters
    }

    @Test func withinTheSelection() throws {
        let second = (text as NSString).range(of: "deploy again; redeploy later.")
        #expect(try TextSearch.matches(of: "deploy", in: text, options: .init(), within: second).count == 2)
    }

    @Test func replacing() throws {
        let plain = try TextSearch.replaceAll("deploy", with: "ship", in: text, options: .init(wholeWord: true))
        #expect(plain.count == 3 && plain.text == "ship to seedbox.\nship again; redeploy later.\nship!")
        let dollars = try TextSearch.replaceAll("seedbox", with: "$5 box", in: text, options: .init())
        #expect(dollars.text.hasPrefix("Deploy to $5 box."))                     // plain: a dollar is a dollar
        let groups = try TextSearch.replaceAll("(\\w+) to (\\w+)", with: "$2 from $1", in: text, options: .init(regex: true))
        #expect(groups.count == 1 && groups.text.hasPrefix("seedbox from Deploy."))
        let one = try TextSearch.replacement(for: NSRange(location: 0, length: 17), in: text, query: "(\\w+) to (\\w+)", template: "$2", options: .init(regex: true))
        #expect(one == "seedbox")
        #expect(try TextSearch.replaceAll("nothing", with: "x", in: text, options: .init()).count == 0)
    }

    @Test func nextAndPrevious() {
        let ranges = [NSRange(location: 2, length: 1), NSRange(location: 10, length: 1), NSRange(location: 20, length: 1)]
        #expect(TextSearch.next(after: 5, in: ranges) == 1)
        #expect(TextSearch.next(after: 25, in: ranges) == 0)                    // wraps to the top
        #expect(TextSearch.next(after: 10, in: ranges, backwards: true) == 0)
        #expect(TextSearch.next(after: 1, in: ranges, backwards: true) == 2)    // wraps to the bottom
        #expect(TextSearch.next(after: 0, in: []) == nil)
    }
}
