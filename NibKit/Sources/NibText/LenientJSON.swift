// Sublime's JSON (PRD HL2, HL3): `.sublime-color-scheme` and `.sublime-settings` files allow
// `//` and `/* */` comments and trailing commas. Both are removed outside strings, then the
// text is read as JSON.

import Foundation

public enum LenientJSON {
    public enum Failure: Error { case notJSON(String) }

    /// The file's top-level object.
    public static func object(from data: Data) throws -> [String: Any] {
        let text = String(decoding: data, as: UTF8.self)
        let clean = strip(text)
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: Any] else {
                throw Failure.notJSON("not an object")
            }
            return object
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.notJSON((error as NSError).userInfo["NSDebugDescription"] as? String ?? error.localizedDescription)
        }
    }

    /// The text without comments, and without a comma before a closing bracket or brace.
    static func strip(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        var pendingComma: String.UnicodeScalarView?   // a comma and the blanks after it, held until the next token
        func flushComma(beforeClose: Bool) {
            if let held = pendingComma {
                if beforeClose { out.append(contentsOf: held.dropFirst()) } else { out.append(contentsOf: held) }
                pendingComma = nil
            }
        }
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if pendingComma != nil, c == " " || c == "\t" || c == "\n" || c == "\r" {
                pendingComma!.append(c)
                i += 1
                continue
            }
            if c == "]" || c == "}" { flushComma(beforeClose: true) } else { flushComma(beforeClose: false) }
            if c == "," { pendingComma = String.UnicodeScalarView([c]); i += 1; continue }
            if c == "\"" { inString = true }
            out.append(c)
            i += 1
        }
        flushComma(beforeClose: false)
        return String(out)
    }
}
