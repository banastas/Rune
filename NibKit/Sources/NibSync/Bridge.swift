// The `nib` command-line tool and the app (PRD AP4, §6.3). The tool never writes synced files
// itself (the sync controls need an app identity, §8 M0): it leaves a request in Nib's support
// folder, launches Nib if it isn't running, and says so with a distributed notification; Nib
// answers with one carrying the same one-time token, and posts another when a file the tool
// waits on (`-w`) has closed. A request is a file, not a URL, so that only a process on this
// Mac that can write to the user's Library can make one (a web page can open a URL).

import Foundation

public enum Bridge {
    public static let bundleID = "com.banastas.nib"
    /// Requests waiting for Nib: `<token>.json`, written whole (by renaming) before anything says so.
    public static var folder: URL { NibPaths.support.appendingPathComponent("Requests", isDirectory: true) }

    /// The notifications' names: the test harness's own (`NibPaths.isScenario`), so that its
    /// `nib` tool and the user's never reach the other's Nib.
    private static let prefix = NibPaths.isScenario ? "com.banastas.nib.scenarios" : "com.banastas.nib"
    /// Tool → app: a request is in the folder (object: its token).
    public static let requestPosted = Notification.Name(prefix + ".request")
    /// App → tool: done, or why not (object: the token; userInfo: "ok" and "message").
    public static let replied = Notification.Name(prefix + ".reply")
    /// App → tool: the file waited on has closed, and its text is in the file (object: the token).
    public static let closed = Notification.Name(prefix + ".closed")

    public struct Request: Codable, Sendable, Equatable {
        public enum Command: String, Codable, Sendable {
            /// Open files (`nib file…`), each at a line if given ("12" or "12:5").
            case open
            /// Standard input as an untitled buffer (`cmd | nib`).
            case new
            /// Standard input at the end of the scratch file (`cmd | nib -a`).
            case append
            /// Show the scratch window (`nib --scratch`).
            case scratch
        }

        public struct File: Codable, Sendable, Equatable {
            public var path: String
            public var line: String?
            public init(path: String, line: String? = nil) { self.path = path; self.line = line }
        }

        public var command: Command
        public var files: [File]
        /// Answer `closed` once these files (or the untitled buffer) have closed.
        public var wait: Bool
        public var text: String?
        /// Bring Nib forward (all but `append`); the scenarios say no, so that typing on the Mac
        /// meanwhile doesn't land in their windows.
        public var forward: Bool

        public init(command: Command, files: [File] = [], wait: Bool = false, text: String? = nil, forward: Bool = true) {
            self.command = command
            self.files = files
            self.wait = wait
            self.text = text
            self.forward = forward && command != .append
        }
    }

    /// `name:12` and `name:12:5`, as `subl` takes them: the file and the line, when no file is
    /// called that whole name.
    public static func file(from argument: String, directory: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Request.File {
        func absolute(_ path: String) -> String {
            let expanded = (path as NSString).expandingTildeInPath
            let full = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
            return URL(fileURLWithPath: full).standardizedFileURL.path
        }
        let whole = absolute(argument)
        guard !exists(whole) else { return Request.File(path: whole) }
        var parts = argument.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var numbers: [String] = []
        while numbers.count < 2, parts.count > 1, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
            numbers.insert(parts.removeLast(), at: 0)
        }
        guard !numbers.isEmpty else { return Request.File(path: whole) }
        return Request.File(path: absolute(parts.joined(separator: ":")), line: numbers.joined(separator: ":"))
    }

    /// Writes the request whole (a rename), so Nib never reads half of one.
    public static func post(_ request: Request, token: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(request)
        let partial = folder.appendingPathComponent(".\(token).partial")
        try data.write(to: partial)
        try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent("\(token).json"))
    }

    /// Takes a request out of the folder, once: whoever renames it first has it.
    public static func take(token: String) -> Request? {
        let file = folder.appendingPathComponent("\(token).json")
        let taken = folder.appendingPathComponent(".\(token).taken")
        guard (try? FileManager.default.moveItem(at: file, to: taken)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: taken) }
        return (try? Data(contentsOf: taken)).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
    }

    /// Requests left in the folder (Nib wasn't running, or missed the notification), oldest
    /// first; those over a minute old are thrown away: whoever asked has given up.
    public static func waiting(now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var tokens: [(String, Date)] = []
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(date) > 60 { try? fm.removeItem(at: file); continue }
            tokens.append((file.deletingPathExtension().lastPathComponent, date))
        }
        return tokens.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
