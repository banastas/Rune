// The `nib` tool's arguments as requests (PRD AP4): paths made absolute from the shell's
// folder, `file:12` and `file:12:5` as `subl` takes them, and a request read back as written.
// (Posting and taking use Nib's real support folder, where a running Nib would take them:
// the `cli` scenario covers those.)

import Foundation
import Testing

@testable import NibSync

@Suite struct BridgeTests {
    @Test func pathsAndLines() {
        let none: (String) -> Bool = { _ in false }
        #expect(Bridge.file(from: "notes.md", directory: "/tmp/work", exists: none) == .init(path: "/tmp/work/notes.md"))
        #expect(Bridge.file(from: "../a/b.txt", directory: "/tmp/work", exists: none) == .init(path: "/tmp/a/b.txt"))
        #expect(Bridge.file(from: "/abs/x.js:12", directory: "/tmp", exists: none) == .init(path: "/abs/x.js", line: "12"))
        #expect(Bridge.file(from: "x.js:12:5", directory: "/tmp", exists: none) == .init(path: "/tmp/x.js", line: "12:5"))
        #expect(Bridge.file(from: "x.js:", directory: "/tmp", exists: none) == .init(path: "/tmp/x.js:"))
        #expect(Bridge.file(from: "x.js:a", directory: "/tmp", exists: none) == .init(path: "/tmp/x.js:a"))
        #expect(Bridge.file(from: "~/n.md", directory: "/tmp", exists: none).path == NSHomeDirectory() + "/n.md")
        // A file really called "log:12" is that file.
        #expect(Bridge.file(from: "log:12", directory: "/tmp", exists: { $0 == "/tmp/log:12" }) == .init(path: "/tmp/log:12"))
    }

    @Test func requestRoundTrip() throws {
        let request = Bridge.Request(command: .open, files: [.init(path: "/tmp/a.md", line: "3")], wait: true, text: nil)
        let back = try JSONDecoder().decode(Bridge.Request.self, from: JSONEncoder().encode(request))
        #expect(back == request && back.forward)
        #expect(!Bridge.Request(command: .append, text: "x").forward)   // appending never brings Nib forward
    }
}
