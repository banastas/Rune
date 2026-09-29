// nib-fidelity (PRD HL7, S3): Nib's highlighting against Sublime's, on the reference files.
// Reads Sublime's dump (fidelity/sublime/*.json, written by NibFidelity.py), highlights the
// same text with Nib, and compares the text color of every non-whitespace character. Prints
// each file's share, the whole, and the largest mismatches by scope; exits 1 under 98%.
//
//   swift run nib-fidelity <fidelity folder> [--all]
//   swift run nib-fidelity --report [scheme file]   (HL4's import report; Sublime's own scheme by default)

import Foundation
import NibSyntax
import NibText

let arguments = CommandLine.arguments
guard arguments.count > 1 else { print("usage: nib-fidelity <fidelity folder> [--all] | --tree <file> | --runs <file> | --report [scheme]"); exit(2) }
if arguments[1] == "--tree", arguments.count > 2 {
    // The syntax tree of a file, for writing queries.
    let url = URL(fileURLWithPath: arguments[2])
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let (language, _) = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: text.components(separatedBy: "\n").first) else { exit(2) }
    print(Highlighter.tree(text, language: language).replacingOccurrences(of: ") (", with: ")\n ("))
    exit(0)
}
if arguments[1] == "--report" {
    // The import report for a scheme file, or for what Import from Sublime would find (read only).
    do {
        if arguments.count > 2 {
            let url = URL(fileURLWithPath: arguments[2])
            let theme = try Theme(document: Theme.document(file: Data(contentsOf: url), named: url.lastPathComponent), fallbackName: url.lastPathComponent)
            print(ThemeReport.facts(for: theme).joined(separator: " · "))
        } else {
            guard let data = SublimeImport.dataFolder() else { print(SublimeImport.Failure.noSublime); exit(1) }
            let found = try SublimeImport(data: data, appPackages: URL(fileURLWithPath: "/Applications/Sublime Text.app/Contents/MacOS/Packages")).run()
            print("\(found.source)\(found.override.map { " + \($0)" } ?? "")")
            print(ThemeReport.facts(for: found.scheme).joined(separator: " · "))
            print("font \(found.fontFace ?? "-") \(found.fontSize.map { String($0) } ?? "-") · tab size \(found.tabSize.map(String.init) ?? "-") · spaces \(found.translateTabsToSpaces.map { String($0) } ?? "-") · word wrap \(found.wordWrap ?? "-") · line padding \(found.linePaddingTop.map { String($0) } ?? "-")/\(found.linePaddingBottom.map { String($0) } ?? "-")")
        }
        exit(0)
    } catch {
        print(error)
        exit(1)
    }
}
if arguments[1] == "--runs", arguments.count > 2 {
    // Each run's text and scopes, for writing queries.
    let url = URL(fileURLWithPath: arguments[2])
    let text = try String(contentsOf: url, encoding: .utf8)
    guard let (language, root) = SyntaxLanguage.detect(fileName: url.lastPathComponent, firstLine: text.components(separatedBy: "\n").first) else { exit(2) }
    for run in Highlighter.runs(text, language: language, root: root) {
        let part = (text as NSString).substring(with: run.range)
        if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        print(String(format: "%-24@ ", "“\(part.prefix(20))”" as NSString) + run.scopes.joined(separator: " "))
    }
    exit(0)
}
let folder = URL(fileURLWithPath: arguments[1])
let showAll = arguments.contains("--all")
let theme = try Theme(tmTheme: Data(contentsOf: folder.deletingLastPathComponent().appendingPathComponent("themes/an-old-hope-nib.tmTheme")))
let dumps = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("sublime"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }

struct Miss: Hashable {
    var sublime: String, nib: String, sublimeScope: String, nibScope: String
}

var totalSame = 0, totalChars = 0
var lines: [String] = []
for dump in dumps {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dump)) as! [String: Any]
    let name = json["file"] as! String
    let text = json["text"] as! String
    guard let (language, root) = SyntaxLanguage.detect(fileName: name, firstLine: text.components(separatedBy: "\n").first) else {
        print("\(name): no syntax"); continue
    }
    // Sublime counts code points; the highlighter counts UTF-16 units.
    let scalars = Array(text.unicodeScalars)
    var utf16At = [Int](repeating: 0, count: scalars.count + 1)
    for (i, scalar) in scalars.enumerated() { utf16At[i + 1] = utf16At[i] + scalar.utf16.count }
    var sublimeColor = [String?](repeating: nil, count: scalars.count), sublimeScope = [String](repeating: "", count: scalars.count)
    for token in json["tokens"] as! [[Any]] {
        let begin = token[0] as! Int, end = token[1] as! Int
        for i in begin..<min(end, scalars.count) {
            sublimeColor[i] = (token[3] as? String)?.uppercased()
            sublimeScope[i] = token[2] as! String
        }
    }
    let runs = Highlighter.runs(text, language: language, root: root)
    var nibColor = [String](repeating: theme.foreground.hex, count: utf16At.last!)
    var nibScope = [String](repeating: "", count: utf16At.last!)
    for run in runs {
        let hex = theme.style(for: run.scopes).foreground.hex, scopes = run.scopes.joined(separator: " ")
        for i in run.range.location..<min(NSMaxRange(run.range), nibColor.count) { nibColor[i] = hex; nibScope[i] = scopes }
    }
    var same = 0, chars = 0
    var misses: [Miss: (count: Int, sample: String)] = [:]
    for (i, scalar) in scalars.enumerated() where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
        chars += 1
        let expected = sublimeColor[i] ?? theme.foreground.hex, got = nibColor[utf16At[i]]
        if expected == got { same += 1; continue }
        func tail(_ scopes: String) -> String { scopes.split(separator: " ").suffix(2).joined(separator: " ") }
        let key = Miss(sublime: expected, nib: got, sublimeScope: tail(sublimeScope[i]), nibScope: tail(nibScope[utf16At[i]]))
        let sample = (misses[key]?.sample ?? "") + (misses[key].map { $0.sample.count < 24 } ?? true ? String(scalar) : "")
        misses[key] = ((misses[key]?.count ?? 0) + 1, sample)
    }
    totalSame += same
    totalChars += chars
    let share = chars == 0 ? 100 : 100 * Double(same) / Double(chars)
    lines.append(String(format: "%-12@ %6.2f%%  (%d of %d characters, %@)", name as NSString, share, same, chars, language.name as NSString))
    for (miss, info) in misses.sorted(by: { $0.value.count > $1.value.count }).prefix(showAll ? 1000 : 8) {
        lines.append("    \(String(format: "%4d", info.count))  Sublime \(miss.sublime) \(miss.sublimeScope)")
        lines.append("          Nib     \(miss.nib) \(miss.nibScope)   “\(info.sample)”")
    }
}
let overall = totalChars == 0 ? 0 : 100 * Double(totalSame) / Double(totalChars)
print(lines.joined(separator: "\n"))
print(String(format: "ALL          %6.2f%%  (%d of %d characters) · the bar is 98%%", overall, totalSame, totalChars))
exit(overall >= 98 ? 0 : 1)
