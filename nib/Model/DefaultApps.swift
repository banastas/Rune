// Nib as the app a double-click opens (PRD open question 15, decided 2026-10-06, the user's call,
// once Nib opened any file). Settings › Files has a switch for each kind of text file: on, Nib
// becomes the default app for its types, as Finder's Get Info › Open With › Change All makes one,
// and remembers the app it took them from; off, that app gets them back, or the one macOS ranks
// next if it's gone. macOS keeps the choice, and may ask the user first for some types. A test
// run's Nib never changes the Mac's: it keeps a stand-in.

import AppKit
import NibSync
import UniformTypeIdentifiers

@MainActor
@Observable
final class DefaultApps {
    static let shared = DefaultApps()

    enum Kind: String, CaseIterable, Identifiable {
        case markdown, text, json, html, css, javaScript, shell

        var id: String { rawValue }

        var name: String {
            switch self {
            case .markdown: "Markdown"
            case .text: "Plain text"
            case .json: "JSON"
            case .html: "HTML"
            case .css: "CSS"
            case .javaScript: "JavaScript"
            case .shell: "Shell scripts"
            }
        }

        /// How their names end.
        var extensions: String {
            switch self {
            case .markdown: ".md"
            case .text: ".txt"
            case .json: ".json"
            case .html: ".html"
            case .css: ".css"
            case .javaScript: ".js"
            case .shell: ".sh, .zsh, .bash"
            }
        }

        /// The types macOS gives those files. Terminal's `.command` stays Terminal's: it runs them.
        var types: [UTType] {
            let identifiers: [String] = switch self {
            case .markdown: ["net.daringfireball.markdown"]
            case .text: ["public.plain-text"]
            case .json: ["public.json"]
            case .html: ["public.html"]
            case .css: ["public.css"]
            case .javaScript: ["com.netscape.javascript-source"]
            case .shell: ["public.shell-script", "public.zsh-script", "public.bash-script"]
            }
            return identifiers.compactMap { UTType($0) }
        }
    }

    /// The app a kind's files open in now: Nib only if every one of its types does.
    struct Opener: Equatable {
        var name: String
        var isNib: Bool
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
    #endif

    private init() {}

    /// As macOS has it now (Finder's Get Info changes it while Nib runs).
    func refresh() {
        var next: [Kind: Opener] = [:]
        for kind in Kind.allCases {
            let apps = kind.types.map { opener(of: $0) }
            let isNib = !apps.isEmpty && apps.allSatisfy { $0.map(Self.isNib) ?? false }
            let other = apps.compactMap { $0 }.first { !Self.isNib($0) }
            next[kind] = Opener(name: isNib ? "Nib" : other.map(Self.name) ?? "no app", isNib: isNib)
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
                    failure = "No other app on this Mac opens \(kind.name) files, so they stay with Nib."
                    return
                }
                app = back
            }
            do {
                try await setOpener(app, for: type)
            } catch {
                failure = "macOS didn't change the app for \(kind.name) files: \(error.localizedDescription)"
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
