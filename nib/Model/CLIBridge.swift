// The `nib` command-line tool's requests (PRD AP4, §6.3), handled in the app: open files (at a
// line), standard input as an untitled buffer or at the end of the scratch file, the scratch
// window. Each is answered once; one that waits (`nib -w`, for $EDITOR and git) hears again
// when its files have closed, their text saved in them, or when Nib quits having saved them.
// Under the safety rule (§8) a file outside the test folders isn't opened: the tool says why.

import AppKit
import NibSync

@MainActor
enum CLIBridge {
    /// Tokens waiting for a file to close, by the file's path.
    private static var waiting: [String: [String]] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func start() {
        DistributedNotificationCenter.default().addObserver(forName: Bridge.requestPosted, object: nil, queue: .main) { note in
            guard let token = note.object as? String else { return }
            MainActor.assumeIsolated { handle(token) }
        }
        // Left while Nib wasn't running: most likely the request that started it.
        Bridge.waiting().forEach(handle)
    }

    /// Once per request: the tool says so every second until it hears back, and another Nib
    /// may have taken it.
    static func handle(_ token: String) {
        guard let request = Bridge.take(token: token) else { return }
        Task { await perform(request, token: token) }
    }

    static func perform(_ request: Bridge.Request, token: String) async {
        switch request.command {
        case .scratch:
            if request.forward { AppDelegate.showScratch() } else { AppDelegate.scratchWindow?.orderFront(nil) }
            reply(token, ok: true)
        case .append:
            // A Nib the tool just started is still opening the scratch file.
            let document = Documents.scratch
            for _ in 0..<150 where !document.ready && document.locked == nil { try? await Task.sleep(for: .milliseconds(100)) }
            let result = Clipboard.append(request.text ?? "", action: "Append", from: "STANDARD INPUT")
            if !NSApp.isActive || AppDelegate.scratchWindow?.isKeyWindow != true { Toast.show(result.hud) }
            switch result {
            case .lines: reply(token, ok: true)
            case .notOpen: reply(token, ok: false, "the scratch file isn't open (\(SyncState.midSentence(document.state.spoken)))")
            case .empty: reply(token, ok: false, "nothing on standard input to append")
            case .readOnly: reply(token, ok: false, "the scratch file is read-only")
            }
        case .new:
            guard let url = Untitled.create(text: request.text ?? "") else {
                reply(token, ok: false, "couldn't make an untitled buffer in \(Untitled.folder.path)")
                return
            }
            if request.wait { waiting[key(url), default: []].append(token) }
            if request.forward { NSApp.activate() }
            AppDelegate.openFile(url)
            reply(token, ok: true, waiting: request.wait ? 1 : 0)
        case .open:
            await open(request, token: token)
        }
    }

    private static func open(_ request: Bridge.Request, token: String) async {
        var problems: [String] = []
        var waits = 0
        var opened: [(Bridge.Request.File, URL)] = []
        for file in request.files {
            let url = URL(fileURLWithPath: file.path)
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue {
                problems.append("\(url.path) is a folder: Nib opens files")
            } else if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                problems.append("\(url.path): its folder doesn't exist, so there's nowhere to make it")   // F3: it exited 0 before
            } else if ScratchLocation.refusal(for: url) != nil {
                problems.append("\(url.path) isn't a test file: in a test run, Nib opens only files in iCloud Drive › Nib › Test")
            } else {
                if request.wait {
                    if key(url) == key(Documents.scratch.url) {
                        problems.append("the scratch file stays open, so there's nothing to wait for")
                    } else {
                        waiting[key(url), default: []].append(token)
                        waits += 1
                    }
                }
                opened.append((file, url))
            }
        }
        if !opened.isEmpty, request.forward { NSApp.activate() }
        // A file over 100 MB opens only if the question is answered Open (ED9): Cancel, and
        // there's nothing to wait for.
        opened = opened.filter { file in
            if AppDelegate.openFile(file.1) { return true }
            problems.append("\(file.1.path) wasn't opened: it's over 100 MB, and the question was answered Cancel")
            if request.wait {
                waiting[key(file.1)]?.removeAll { $0 == token }
                waits -= 1
            }
            return false
        }
        // Anything opened is an answer; only nothing opened is a failure.
        reply(token, ok: !opened.isEmpty, problems.joined(separator: "\nnib: "), waiting: waits)
        for (file, url) in opened {
            guard let line = file.line else { continue }
            for _ in 0..<100 {
                if let document = Documents.existing(for: url), document.ready { document.goToLine(line); break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Its window has closed and its text is in the file (or its History, untitled).
    static func closed(_ url: URL) {
        for token in waiting.removeValue(forKey: key(url)) ?? [] { post(Bridge.closed, token, ["path": url.path]) }
    }

    /// Quitting, every file saved and handed back: nothing is left to wait for.
    static func quitting() {
        for (path, tokens) in waiting { for token in tokens { post(Bridge.closed, token, ["path": path]) } }
        waiting = [:]
    }

    private static func reply(_ token: String, ok: Bool, _ message: String = "", waiting: Int = 0) {
        post(Bridge.replied, token, ["ok": ok, "message": message, "waiting": waiting])
    }

    private static func post(_ name: Notification.Name, _ token: String, _ info: [String: Any]) {
        DistributedNotificationCenter.default().postNotificationName(name, object: token, userInfo: info, deliverImmediately: true)
    }

    #if DEBUG
    /// For the `cli` scenario: how many tokens wait on this file.
    static func waiters(for url: URL) -> Int { waiting[key(url)]?.count ?? 0 }
    #endif
}
