// Nib as the app a double-click opens (PRD open question 15, decided 2026-10-06, the user's call,
// once Nib opened any file). Settings › Files has a switch for each kind of text file: on, Nib
// becomes the default app for its types, as Finder's Get Info › Open With › Change All makes one,
// and remembers the app it took them from; off, that app gets them back, or the one macOS ranks
// next if it's gone. macOS keeps the choice, and may ask the user first for some types. A test
// run's Nib never changes the Mac's: it keeps a stand-in.
//
// Not HTML (the user's call, 2026-10-07): macOS opens every page on the Mac with the app for
// .html, `open page.html`, Python's webbrowser, the reports build tools open, links in Terminal
// and Mail, so with Nib as it those came up as source. Nib still edits HTML, highlighted, when
// asked (Open With, ⌘O, `nib page.html`); a Mac where it had them gives them back once.

import AppKit
import NibSync
import NibText
import UniformTypeIdentifiers

@MainActor
@Observable
final class DefaultApps {
    static let shared = DefaultApps()

    enum Kind: String, CaseIterable, Identifiable {
        case markdown, text, json, css, javaScript, shell

        var id: String { rawValue }

        var name: String {
            switch self {
            case .markdown: "Markdown"
            case .text: "Plain text"
            case .json: "JSON"
            case .css: "CSS"
            case .javaScript: "JavaScript"
            case .shell: "Shell scripts"
            }
        }

        /// How their names end: the extensions macOS gives their types (one each was shown: F69).
        var extensions: String {
            switch self {
            case .markdown: ".md, .markdown"
            case .text: ".txt, .text"
            case .json: ".json"
            case .css: ".css"
            case .javaScript: ".js, .mjs"
            case .shell: ".sh, .zsh, .bash"
            }
        }

        /// The kind mid-sentence: "plain text files", "shell scripts" (it was "Shell scripts files": F69).
        var inSentence: String {
            switch self {
            case .markdown: "Markdown files"
            case .text: "plain text files"
            case .json: "JSON files"
            case .css: "CSS files"
            case .javaScript: "JavaScript files"
            case .shell: "shell scripts"
            }
        }

        /// The row's second line: its extensions, and the app that has them when it isn't Nib.
        func detail(_ opener: Opener?) -> String {
            guard let opener, !opener.isNib else { return extensions }
            if let partly = opener.partly { return "\(extensions) · \(partly)" }
            return opener.name == "no app" ? "\(extensions) · no app opens them now" : "\(extensions) · now \(opener.name)"
        }

        /// The types macOS gives those files. Terminal's `.command` stays Terminal's: it runs them.
        var types: [UTType] {
            let identifiers: [String] = switch self {
            case .markdown: ["net.daringfireball.markdown"]
            case .text: ["public.plain-text"]
            case .json: ["public.json"]
            case .css: ["public.css"]
            case .javaScript: ["com.netscape.javascript-source"]
            case .shell: ["public.shell-script", "public.zsh-script", "public.bash-script"]
            }
            return identifiers.compactMap { UTType($0) }
        }
    }

    /// The app a kind's files open in now: Nib only if every one of its types does; when only some
    /// do (macOS asks for each shell type, and one can be declined), which are still elsewhere.
    struct Opener: Equatable {
        var name: String
        var isNib: Bool
        var partly: String? = nil
    }

    private(set) var openers: [Kind: Opener] = [:]
    private(set) var changing: Set<Kind> = []
    private(set) var failure: String?

    #if DEBUG
    /// The scenarios' stand-in, by type: changing the Mac's would change the user's. A type not in
    /// it reads as the Mac has it.
    private var fake: [String: URL]? = NibPaths.isScenario ? [:] : nil

    /// The `defaultapps` scenario's starting point.
    func pretend(_ app: URL, opens kind: Kind) {
        for type in kind.types { fake?[type.identifier] = app }
        refresh()
    }

    /// The same for one type: HTML, which isn't a kind.
    func pretend(_ app: URL, opensType identifier: String) {
        fake?[identifier] = app
    }
    #endif

    static let htmlGivenBackKey = "htmlGivenBack"

    /// HTML, given back once where Nib had it (it was a kind until 2026-10-07): to the app Nib took
    /// it from, or the Mac's web browser if that's gone. What to say on the strip, or nil when
    /// there was nothing to do.
    func giveBackHTML() async -> String? {
        guard !NibDefaults.store.bool(forKey: Self.htmlGivenBackKey) else { return nil }
        NibDefaults.store.set(true, forKey: Self.htmlGivenBackKey)   // once, whatever comes of it
        guard let html = UTType("public.html"), opener(of: html).map(Self.isNib) == true else { return nil }
        var back: URL?
        if let path = NibDefaults.store.string(forKey: Self.beforeKey(html)), FileManager.default.fileExists(atPath: path), !Self.isNib(URL(fileURLWithPath: path)) {
            back = URL(fileURLWithPath: path)
        } else if let web = URL(string: "https://example.com"), let browser = NSWorkspace.shared.urlForApplication(toOpen: web), !Self.isNib(browser) {
            back = browser
        } else {
            back = previous(for: html)
        }
        guard let back else { return "HTML FILES STAY WITH NIB · NO OTHER APP ON THIS MAC OPENS THEM" }
        let name = Self.name(back).uppercased()
        do {
            try await setOpener(back, for: html)
            return "HTML FILES OPEN IN \(name) AGAIN · NIB STILL EDITS THEM: OPEN WITH, ⌘O OR NIB PAGE.HTML"
        } catch {
            return "COULDN'T GIVE HTML FILES BACK TO \(name) · \(ErrorWords.hud(error)) · FINDER'S GET INFO › OPEN WITH CAN"
        }
    }

    private init() {}

    /// As macOS has it now (Finder's Get Info changes it while Nib runs).
    func refresh() {
        var next: [Kind: Opener] = [:]
        for kind in Kind.allCases {
            let apps = kind.types.map { opener(of: $0) }
            let isNib = !apps.isEmpty && apps.allSatisfy { $0.map(Self.isNib) ?? false }
            let other = apps.compactMap { $0 }.first { !Self.isNib($0) }
            // Some of its types Nib's and some not: "now Xcode" read as if none were (F69).
            let elsewhere = zip(kind.types, apps).filter { $0.1.map(Self.isNib) != true }
            let partly = !isNib && elsewhere.count < apps.count
                ? elsewhere.map { "." + ($0.0.preferredFilenameExtension ?? "?") }.joined(separator: " and ") + " still with \(other.map(Self.name) ?? "no app")"
                : nil
            next[kind] = Opener(name: isNib ? "Nib" : other.map(Self.name) ?? "no app", isNib: isNib, partly: partly)
        }
        openers = next
    }

    func set(_ kind: Kind, _ on: Bool) async {
        failure = nil
        changing.insert(kind)
        defer {
            changing.remove(kind)
            refresh()
        }
        for type in kind.types {
            let now = opener(of: type)
            let app: URL
            if on {
                guard now.map(Self.isNib) != true else { continue }
                if let now { NibDefaults.store.set(now.path, forKey: Self.beforeKey(type)) }
                app = Bundle.main.bundleURL
            } else {
                guard now.map(Self.isNib) == true else { continue }
                guard let back = previous(for: type) else {
                    failure = "No other app on this Mac opens \(kind.inSentence), so they stay with Nib."
                    return
                }
                app = back
            }
            do {
                try await setOpener(app, for: type)
            } catch {
                failure = "macOS didn't change the app for \(kind.inSentence): \(error.localizedDescription)"
                return
            }
        }
    }

    /// The app a type opened in before Nib, if it's still there; if not, the one macOS ranks first
    /// after Nib.
    func previous(for type: UTType) -> URL? {
        if let path = NibDefaults.store.string(forKey: Self.beforeKey(type)), FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if !Self.isNib(url) { return url }
        }
        return NSWorkspace.shared.urlsForApplications(toOpen: type).first { !Self.isNib($0) }
    }

    func opener(of type: UTType) -> URL? {
        #if DEBUG
        if let fake { return fake[type.identifier] ?? NSWorkspace.shared.urlForApplication(toOpen: type) }
        #endif
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    private func setOpener(_ app: URL, for type: UTType) async throws {
        #if DEBUG
        if fake != nil { fake?[type.identifier] = app; return }
        #endif
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }

    static func beforeKey(_ type: UTType) -> String { "openedBefore:" + type.identifier }

    /// Any copy of Nib: macOS opens the newest one it knows (an installed one, before a build).
    static func isNib(_ app: URL) -> Bool {
        Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func name(_ app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }
}
