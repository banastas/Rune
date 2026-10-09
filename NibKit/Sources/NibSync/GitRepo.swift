// Changes since the last commit (PRD ED12): the committed version of a file, from git. Only for a
// file inside a repository (a `.git` above it), and only where git is installed: on a Mac without
// the developer tools, `/usr/bin/git` puts up macOS's "install the command line developer tools"
// dialog, so `xcode-select -p` is asked first, once. Every call has a time limit, and nothing here
// writes to the repository (GIT_OPTIONAL_LOCKS=0, as editors' status reads do).

import Foundation
import NibText

public enum GitRepo {
    public struct Base: Equatable, Sendable {
        /// The file as the last commit has it ("" for a file added since).
        public let text: String
        /// The commit it's from, to see when that changes.
        public let head: String
        /// "main", or nil when HEAD isn't on a branch.
        public let branch: String?
    }

    public enum Answer: Equatable, Sendable {
        case base(Base)
        /// In a repository, not tracked by git.
        case untracked(branch: String?)
        /// No repository above it, or git isn't installed, or git didn't answer.
        case none
    }

    /// The repository's `.git` above `file`, if any (a folder, or a worktree's file).
    public static func dotGit(above file: URL) -> URL? {
        var folder = file.resolvingSymlinksInPath().deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// The file git appends to at every move of HEAD (a commit, a checkout, a reset): watched to
    /// know when the committed version may have changed. A worktree's `.git` is a file naming its
    /// own git folder.
    public static func headLog(for dotGit: URL) -> URL? {
        var folder = dotGit
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isFolder), !isFolder.boolValue,
           let text = try? String(contentsOf: dotGit, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            folder = URL(fileURLWithPath: path, relativeTo: dotGit.deletingLastPathComponent()).standardizedFileURL
        }
        let log = folder.appendingPathComponent("logs/HEAD")
        return FileManager.default.fileExists(atPath: log.path) ? log : nil
    }

    /// Whether git can be run without macOS offering to install it.
    public static let installed: Bool = {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcode-select") else { return false }
        return (try? run("/usr/bin/xcode-select", ["-p"], in: nil, seconds: 3))?.status == 0
    }()

    /// The committed version of `file`, its commit and branch; `.none` outside a repository.
    public static func committed(_ file: URL) -> Answer {
        guard dotGit(above: file) != nil, installed else { return .none }
        let real = file.resolvingSymlinksInPath()
        let folder = real.deletingLastPathComponent(), name = real.lastPathComponent
        // The branch even before its first commit; nil when HEAD isn't on one (detached).
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"], in: folder).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard git(["ls-files", "--error-unmatch", "--", name], in: folder) != nil else { return .untracked(branch: branch) }
        guard let head = git(["rev-parse", "HEAD"], in: folder).flatMap({ String(data: $0, encoding: .utf8) })?
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            return .base(Base(text: "", head: "", branch: branch))   // a repository with no commit yet
        }
        // Tracked (staged) but not in the last commit: a new file, every line added.
        let data = git(["show", "HEAD:./" + name], in: folder) ?? Data()
        return .base(Base(text: TextFile.decode(data).text, head: head, branch: branch))
    }

    /// The commit HEAD is at, to see whether the committed version may have changed.
    public static func head(of file: URL) -> String? {
        guard dotGit(above: file) != nil, installed else { return nil }
        return git(["rev-parse", "HEAD"], in: file.resolvingSymlinksInPath().deletingLastPathComponent())
            .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git's output, or nil if it failed or ran past its time.
    static func git(_ arguments: [String], in folder: URL?) -> Data? {
        guard let result = try? run("/usr/bin/git", arguments, in: folder, seconds: 5), result.status == 0 else { return nil }
        return result.output
    }

    static func run(_ tool: String, _ arguments: [String], in folder: URL?, seconds: Double) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let folder { process.currentDirectoryURL = folder }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"      // never take the index lock to refresh it
        environment["GIT_TERMINAL_PROMPT"] = "0"     // never wait on a prompt
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read as it comes (a big file fills the pipe's buffer before git can exit), with a limit.
        let deadline = DispatchTime.now() + seconds
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: deadline)
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return (process.terminationReason == .uncaughtSignal ? -1 : process.terminationStatus, output)
    }
}
