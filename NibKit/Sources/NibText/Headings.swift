// The headings list (PRD SC7, ⌘R, Sublime's Goto Symbol): a Markdown file's headings, as
// CommonMark reads them, found a line at a time without the syntax tree (which a big file keeps
// for the stretch round the view only). ATX headings ("## Title", up to three spaces in, a
// closing run of #s dropped) and setext headings (a paragraph underlined with === or ---); none
// inside fenced code, HTML comments or front matter, and none indented four spaces (code).

import Foundation

public struct Heading: Equatable, Sendable {
    /// 1 to 6.
    public var level: Int
    public var title: String
    /// Where its line starts (UTF-16), and the line (1-based).
    public var location: Int
    public var line: Int

    public init(level: Int, title: String, location: Int, line: Int) {
        self.level = level
        self.title = title
        self.location = location
        self.line = line
    }
}

public enum Headings {
    public static func markdown(in text: NSString) -> [Heading] {
        var found: [Heading] = []
        var fence: (character: unichar, count: Int)?   // inside fenced code: what closes it
        var inComment = false
        var paragraph: (location: Int, line: Int, end: Int)?   // the paragraph a setext line would underline
        var lineNumber = 0
        var start = 0
        let length = text.length
        var head = [unichar](repeating: 0, count: 8)

        // Front matter: "---" as the very first line, to the next "---" (or "...").
        if length >= 4, text.substring(with: NSRange(location: 0, length: 4)) == "---\n" {
            var end = 0, contents = 0, at = 4
            lineNumber = 1
            while at < length {
                text.getLineStart(nil, end: &end, contentsEnd: &contents, for: NSRange(location: at, length: 0))
                lineNumber += 1
                let line = text.substring(with: NSRange(location: at, length: contents - at)).trimmingCharacters(in: .whitespaces)
                at = end
                if line == "---" || line == "..." { start = end; break }
            }
            if start == 0 { lineNumber = 0 }   // never closed: not front matter after all
        }

        while start < length {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            lineNumber += 1
            let lineLength = contentsEnd - start
            defer { start = end }
            let peek = min(8, lineLength)
            text.getCharacters(&head, range: NSRange(location: start, length: peek))
            var indent = 0
            while indent < peek, head[indent] == 0x20 { indent += 1 }
            let blank = indent == lineLength || (indent < peek && head[indent] == 0x09 && line(text, start, contentsEnd).allSatisfy { $0 == " " || $0 == "\t" })
            let first: unichar = indent < peek ? head[indent] : 0

            if let open = fence {
                // Fenced code runs to a line of the same character, as many or more, and nothing else.
                if indent <= 3, first == open.character {
                    let rest = line(text, start, contentsEnd).trimmingCharacters(in: .whitespaces)
                    if rest.count >= open.count, rest.utf16.allSatisfy({ $0 == open.character }) { fence = nil }
                }
                continue
            }
            if inComment {
                if line(text, start, contentsEnd).contains("-->") { inComment = false }
                continue
            }
            if blank { paragraph = nil; continue }
            guard indent <= 3 else {
                // Indented code, or a paragraph's continuation: never a heading's line.
                if paragraph != nil { paragraph?.end = contentsEnd }
                continue
            }
            let content = line(text, start, contentsEnd)
            let trimmed = content.trimmingCharacters(in: .whitespaces)

            if first == 0x60 || first == 0x7E {   // ``` or ~~~
                let run = trimmed.utf16.prefix { $0 == first }.count
                if run >= 3, first != 0x60 || !trimmed.dropFirst(run).contains("`") {
                    fence = (first, run)
                    paragraph = nil
                    continue
                }
            }
            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") { inComment = true }
                paragraph = nil
                continue
            }
            if first == 0x23 {   // #
                let hashes = trimmed.utf16.prefix { $0 == 0x23 }.count
                let after = trimmed.dropFirst(hashes)
                if hashes <= 6, after.isEmpty || after.first == " " || after.first == "\t" {
                    var title = after.trimmingCharacters(in: .whitespaces)
                    // A closing run of #s, after a space (or the whole title), isn't part of it.
                    if let last = title.lastIndex(where: { $0 != "#" }) {
                        if title[last] == " " || title[last] == "\t" { title = String(title[...last]).trimmingCharacters(in: .whitespaces) }
                    } else {
                        title = ""
                    }
                    if !title.isEmpty { found.append(Heading(level: hashes, title: title, location: start, line: lineNumber)) }
                    paragraph = nil
                    continue
                }
            }
            if let open = paragraph, first == 0x3D || first == 0x2D {   // = or -, under a paragraph
                if !trimmed.isEmpty, trimmed.utf16.allSatisfy({ $0 == first }) {
                    let title = text.substring(with: NSRange(location: open.location, length: open.end - open.location))
                        .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                    found.append(Heading(level: first == 0x3D ? 1 : 2, title: title, location: open.location, line: open.line))
                    paragraph = nil
                    continue
                }
            }
            // A line that starts a paragraph, or goes on with one. Not a list item, a quote or a
            // table's row (a setext line under those is a rule, or text); not a rule itself.
            let startsBlock = trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || isListItem(trimmed) || isRule(trimmed)
            if startsBlock {
                paragraph = nil
            } else if paragraph != nil {
                paragraph?.end = contentsEnd
            } else {
                paragraph = (start, lineNumber, contentsEnd)
            }
        }
        return found
    }

    private static func line(_ text: NSString, _ start: Int, _ end: Int) -> String {
        text.substring(with: NSRange(location: start, length: end - start))
    }

    /// "- ", "* ", "+ ", "1. ", "1) ".
    private static func isListItem(_ line: String) -> Bool {
        if let first = line.first, "-*+".contains(first) { return line.count == 1 || line.dropFirst().first == " " || line.dropFirst().first == "\t" }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")" else { return false }
        return rest.count == 1 || rest.dropFirst().first == " " || rest.dropFirst().first == "\t"
    }

    /// A thematic break: three or more of *, - or _, spaces between allowed.
    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "*-_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }
}
