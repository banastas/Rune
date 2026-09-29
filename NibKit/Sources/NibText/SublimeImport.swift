// Import from Sublime Text (PRD HL3): its color scheme, with an override from Packages/User/,
// and its font and text settings, read as Sublime reads them and never changed. Settings are
// layered as Sublime layers them: Default's Preferences, Default's "Preferences (OSX)", then
// the user's two. A scheme is found loose in Packages/, in Installed Packages/, or among the
// app's own packages; packages are zips, read in memory (L1).

import Foundation

public struct SublimeImport: Sendable {
    public struct Found: Sendable {
        public var scheme: Theme
        /// The scheme as Nib keeps it: one `.sublime-color-scheme`, the override applied.
        public var document: Data
        /// Where it was found ("Packages/User/an-old-hope.tmTheme"), and its override if any.
        public var source: String
        public var override: String?
        public var fontFace: String?
        public var fontSize: Double?
        public var linePaddingTop: Double?
        public var linePaddingBottom: Double?
        public var tabSize: Int?
        public var translateTabsToSpaces: Bool?
        /// "auto", "true" or "false".
        public var wordWrap: String?
        /// `line_numbers`, and whether `draw_white_space` is "all" (ED6; Sublime's "selection"
        /// shows them only in the selection, which Nib doesn't do: off).
        public var lineNumbers: Bool? = nil
        public var invisibles: Bool? = nil
        /// `trim_trailing_white_space_on_save` (true, or "all" and "not_on_caret" in Sublime 4)
        /// and `ensure_newline_at_eof_on_save`: Nib does them on ⌘S (ED6).
        public var trimOnSave: Bool? = nil
        public var newlineOnSave: Bool? = nil
    }

    public enum Failure: Error, CustomStringConvertible {
        case noSublime
        case noScheme(String)
        case unreadable(String, String)

        /// In the HUD's words (W1).
        public var description: String {
            switch self {
            case .noSublime: "SUBLIME TEXT NOT FOUND · NOTHING IMPORTED"
            case .noScheme(let name): "SUBLIME TEXT'S SCHEME “\(name.uppercased())” NOT FOUND · NOTHING IMPORTED"
            case .unreadable(let name, let why): "COULDN'T READ “\(name.uppercased())” · \(why.uppercased()) · NOTHING IMPORTED"
            }
        }
    }

    /// Sublime's data folder (~/Library/Application Support/Sublime Text) and the app's own
    /// packages (…/Sublime Text.app/Contents/MacOS/Packages).
    public let data: URL
    public let appPackages: URL?

    public init(data: URL, appPackages: URL?) {
        self.data = data
        self.appPackages = appPackages
    }

    /// Sublime Text 4's folder, or 3's.
    public static func dataFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        for name in ["Sublime Text", "Sublime Text 3"] {
            let url = home.appendingPathComponent("Library/Application Support/\(name)")
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Packages").path) { return url }
        }
        return nil
    }

    public func run() throws -> Found {
        guard FileManager.default.fileExists(atPath: data.appendingPathComponent("Packages").path) else { throw Failure.noSublime }
        let settings = preferences()
        var schemeName = settings["color_scheme"] as? String ?? "Mariana.sublime-color-scheme"
        if schemeName == "auto" { schemeName = settings["dark_color_scheme"] as? String ?? "Mariana.sublime-color-scheme" }
        guard let (path, bytes) = resource(schemeName) else { throw Failure.noScheme((schemeName as NSString).lastPathComponent) }
        let file = (path as NSString).lastPathComponent, stem = (file as NSString).deletingPathExtension
        var document: [String: Any]
        do {
            document = try Theme.document(file: bytes, named: file)
        } catch {
            throw Failure.unreadable(file, "not a color scheme")
        }
        var override: String?
        let overridePath = "Packages/User/\(stem).sublime-color-scheme"
        if overridePath != path, let extra = try? Data(contentsOf: data.appendingPathComponent(overridePath)) {
            guard let overrideDocument = try? LenientJSON.object(from: extra) else { throw Failure.unreadable("\(stem).sublime-color-scheme", "not JSON") }
            document = Theme.merging(document, overrideDocument)
            override = overridePath
        }
        let scheme = try Theme(document: document, fallbackName: stem)
        let stored = try Theme.storable(document)
        func number(_ key: String) -> Double? { (settings[key] as? NSNumber).flatMap { Self.isBool($0) ? nil : $0.doubleValue } }
        let face = (settings["font_face"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let wrap: String? = switch settings["word_wrap"] {
        case let text as String: text
        case let flag as NSNumber: flag.boolValue ? "true" : "false"
        default: nil
        }
        return Found(scheme: scheme, document: stored, source: path, override: override,
                     fontFace: face, fontSize: number("font_size"),
                     linePaddingTop: number("line_padding_top"), linePaddingBottom: number("line_padding_bottom"),
                     tabSize: number("tab_size").map { Int($0) },
                     translateTabsToSpaces: (settings["translate_tabs_to_spaces"] as? NSNumber).map(\.boolValue),
                     wordWrap: wrap,
                     lineNumbers: (settings["line_numbers"] as? NSNumber).map(\.boolValue),
                     invisibles: Self.drawsAllWhiteSpace(settings["draw_white_space"]),
                     trimOnSave: Self.trims(settings["trim_trailing_white_space_on_save"]),
                     newlineOnSave: (settings["ensure_newline_at_eof_on_save"] as? NSNumber).map(\.boolValue))
    }

    /// `trim_trailing_white_space_on_save`: true, "all" or "not_on_caret" is on; false or "none" off.
    static func trims(_ value: Any?) -> Bool? {
        switch value {
        case let text as String: text != "none"
        case let flag as NSNumber: flag.boolValue
        default: nil
        }
    }

    /// `draw_white_space`: "all" (or a list with "all" in it, as Sublime 4 allows) is on.
    static func drawsAllWhiteSpace(_ value: Any?) -> Bool? {
        switch value {
        case let text as String: text == "all"
        case let list as [Any]: list.contains { ($0 as? String) == "all" }
        default: nil
        }
    }

    /// Sublime's preferences as it sees them: later files win.
    func preferences() -> [String: Any] {
        var merged: [String: Any] = [:]
        for path in ["Packages/Default/Preferences.sublime-settings", "Packages/Default/Preferences (OSX).sublime-settings",
                     "Packages/User/Preferences.sublime-settings", "Packages/User/Preferences (OSX).sublime-settings"] {
            guard let (_, bytes) = resource(path), let object = try? LenientJSON.object(from: bytes) else { continue }
            for (key, value) in object { merged[key] = value }
        }
        return merged
    }

    /// A resource by Sublime's path ("Packages/User/x.tmTheme") or by file name alone
    /// ("Mariana.sublime-color-scheme"): loose first, then Installed Packages, then the app's.
    func resource(_ name: String) -> (path: String, data: Data)? {
        let parts = name.split(separator: "/", maxSplits: 2).map(String.init)
        if parts.count == 3, parts[0] == "Packages" {
            let (package, inner) = (parts[1], parts[2])
            if let loose = try? Data(contentsOf: data.appendingPathComponent(name)) { return (name, loose) }
            for folder in zipFolders {
                if let zip = ZipArchive(url: folder.appendingPathComponent("\(package).sublime-package")), let bytes = zip.contents(of: inner) {
                    return (name, bytes)
                }
            }
            return nil
        }
        // A file name alone: Sublime finds it in whichever package has it.
        let packages = data.appendingPathComponent("Packages")
        if let walk = FileManager.default.enumerator(at: packages, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in walk where url.lastPathComponent == name {
                let path = "Packages/" + url.path.dropFirst(packages.path.count + 1)
                if let bytes = try? Data(contentsOf: url) { return (path, bytes) }
            }
        }
        for folder in zipFolders {
            let zips = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "sublime-package" }.sorted { $0.path < $1.path } ?? []
            for url in zips {
                guard let zip = ZipArchive(url: url) else { continue }
                for entry in zip.entries.keys.sorted() where (entry as NSString).lastPathComponent == name {
                    if let bytes = zip.contents(of: entry) {
                        return ("Packages/\(url.deletingPathExtension().lastPathComponent)/\(entry)", bytes)
                    }
                }
            }
        }
        return nil
    }

    private var zipFolders: [URL] {
        [data.appendingPathComponent("Installed Packages")] + (appPackages.map { [$0] } ?? [])
    }

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// A property list's values as JSON can hold them (dates and data as text).
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]: dictionary.mapValues(jsonSafe)
        case let list as [Any]: list.map(jsonSafe)
        case is String, is NSNumber, is NSNull: value
        default: "\(value)"
        }
    }
}
