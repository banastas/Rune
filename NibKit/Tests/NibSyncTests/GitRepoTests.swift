// Changes since the last commit (PRD ED12): the committed version from a real repository, made in
// a temporary folder (skipped where git isn't installed).

import Foundation
import Testing

@testable import NibSync

@Suite struct GitRepoTests {
    func sh(_ command: String, in folder: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    @Test func committedVersion() throws {
        guard GitRepo.installed else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rune-git-\(UUID().uuidString)")
        let sub = folder.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        sh("git init -q -b main && git config user.email t@example.com && git config user.name Test", in: folder)
        let file = sub.appendingPathComponent("notes.md")
        try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(GitRepo.committed(file) == .untracked(branch: "main"), "not added yet")
        sh("git add docs/notes.md && git commit -q -m first", in: folder)
        try "one\nTWO\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        guard case .base(let base) = GitRepo.committed(file) else { Issue.record("no base"); return }
        #expect(base.text == "one\ntwo\n", "the committed text, not the file now")
        #expect(base.branch == "main" && base.head.count == 40)
        #expect(GitRepo.head(of: file) == base.head)
        #expect(GitRepo.headLog(for: folder.appendingPathComponent(".git")) != nil, "the log of HEAD's moves, watched for commits")
        sh("git commit -qam second", in: folder)
        #expect(GitRepo.head(of: file) != base.head, "a commit moves HEAD")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rune-not-git-\(UUID().uuidString).md")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(GitRepo.committed(outside) == .none, "no repository above it: git isn't run")
    }
}
