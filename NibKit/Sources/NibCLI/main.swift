// nib: the command line's way into Nib (PRD AP4), like Sublime's `subl`. It asks the running
// app, launching it if needed (NibSync's Bridge); it never writes a synced file itself.
//
//   nib file…              open files (file:12 and file:12:5 go to a line)
//   nib -w file…           wait until they're closed ($EDITOR, git commit messages)
//   cmd | nib              standard input as an untitled buffer (-w waits for it to close)
//   cmd | nib -a           standard input at the end of the scratch file
//   nib --scratch          the scratch window (as does `nib` alone)
//
// Exits 0 when done, 1 when Nib says no (or quits before a file waited on is closed), 2 for
// a mistake in the arguments. The scenarios set NIB_NO_LAUNCH (never start Nib) and
// NIB_NO_ACTIVATE (never bring it forward).

import AppKit
import NibSync
import NibText

let usage = """
    usage: nib [-w] [file[:line[:column]] …]
           cmd | nib [-w]      standard input as an untitled buffer
           cmd | nib -a        standard input at the end of the scratch file
           nib --scratch       the scratch window

      -w, --wait      wait until the files are closed (for $EDITOR and git)
      -a, --append    append standard input to the scratch file
      -               read standard input
      -h, --help      this
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("nib: \(message)\n".utf8))
    exit(code)
}

// MARK: The arguments

var wait = false, append = false, scratch = false, readInput = false
var arguments: [String] = []
var options = true
for argument in CommandLine.arguments.dropFirst() {
    if options, argument == "--" { options = false; continue }
    if options, argument == "-" { readInput = true; continue }
    if options, argument.hasPrefix("--") {
        switch argument {
        case "--wait": wait = true
        case "--append": append = true
        case "--scratch": scratch = true
        case "--help": print(usage); exit(0)
        default: fail("no option \(argument)\n\(usage)", code: 2)
        }
        continue
    }
    if options, argument.hasPrefix("-"), argument.count > 1 {
        for flag in argument.dropFirst() {
            switch flag {
            case "w": wait = true
            case "a": append = true
            case "h": print(usage); exit(0)
            default: fail("no option -\(flag)\n\(usage)", code: 2)
            }
        }
        continue
    }
    arguments.append(argument)
}

let piped = isatty(FileHandle.standardInput.fileDescriptor) == 0
func input() -> String {
    TextFile.decode(FileHandle.standardInput.readDataToEndOfFile()).text
}

var request: Bridge.Request
if scratch {
    guard arguments.isEmpty, !append else { fail("--scratch takes nothing else", code: 2) }
    request = Bridge.Request(command: .scratch)
} else if append {
    guard arguments.isEmpty else { fail("-a appends standard input, not files: cat file | nib -a", code: 2) }
    guard piped || readInput else { fail("-a appends standard input, and nothing is piped in: cmd | nib -a", code: 2) }
    let text = input()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("nothing on standard input to append") }
    request = Bridge.Request(command: .append, text: text)
} else if !arguments.isEmpty {
    let directory = FileManager.default.currentDirectoryPath
    request = Bridge.Request(command: .open, files: arguments.map { Bridge.file(from: $0, directory: directory) }, wait: wait)
} else if piped || readInput {
    request = Bridge.Request(command: .new, wait: wait, text: input())
} else {
    request = Bridge.Request(command: .scratch)
}

if ProcessInfo.processInfo.environment["NIB_NO_ACTIVATE"] != nil { request.forward = false }

// MARK: Asking Nib

let token = UUID().uuidString
let center = DistributedNotificationCenter.default()
nonisolated(unsafe) var reply: (ok: Bool, message: String, waiting: Int)?
nonisolated(unsafe) var closed = Set<String>()
center.addObserver(forName: Bridge.replied, object: token, queue: .main) { note in
    let info = note.userInfo ?? [:]
    reply = ((info["ok"] as? Bool) ?? false, (info["message"] as? String) ?? "", (info["waiting"] as? Int) ?? 0)
}
center.addObserver(forName: Bridge.closed, object: token, queue: .main) { note in
    closed.insert((note.userInfo?["path"] as? String) ?? "\(closed.count)")
}

func running() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: Bridge.bundleID).first { !$0.isTerminated }
}

do {
    try Bridge.post(request, token: token)
} catch {
    fail("couldn't leave the request for Nib: \(error.localizedDescription)")
}
// Appending doesn't bring Nib forward (SC6); everything else does.
let forward = request.forward
if let app = running() {
    if forward { app.activate() }
} else if ProcessInfo.processInfo.environment["NIB_NO_LAUNCH"] != nil {
    fail("Nib isn't running")
} else {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = (forward ? [] : ["-g"]) + ["-b", Bridge.bundleID]
    open.standardError = FileHandle.nullDevice
    do { try open.run() } catch { fail("couldn't start Nib: \(error.localizedDescription)") }
    open.waitUntilExit()
    if open.terminationStatus != 0 { fail("couldn't start Nib: macOS doesn't know an app with the ID \(Bridge.bundleID)") }
}

// Said again each second until Nib answers: a Nib just starting takes the request from the
// folder by itself, and one already running hears this.
let deadline = Date().addingTimeInterval(30)
while reply == nil, Date() < deadline {
    center.postNotificationName(Bridge.requestPosted, object: token, userInfo: nil, deliverImmediately: true)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
}
guard let reply else {
    try? FileManager.default.removeItem(at: Bridge.folder.appendingPathComponent("\(token).json"))
    fail("Nib didn't answer in 30 s")
}
if !reply.message.isEmpty {
    FileHandle.standardError.write(Data("nib: \(reply.message)\n".utf8))
}
guard reply.ok else { exit(1) }

// MARK: Waiting (-w)

while closed.count < reply.waiting {
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    if closed.count < reply.waiting, running() == nil {
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // a quit's last notifications
        if closed.count < reply.waiting { fail("Nib quit before the file was closed") }
    }
}
exit(0)
