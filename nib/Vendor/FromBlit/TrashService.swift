// From Blit (/Volumes/Photography/_GitHub/blit), Blit/Model/TrashService.swift at 129babc
// (Blit 0.2.35), copied 2026-10-01 for PRD §4.9 row 13 and adapted; Nib's own code from here.
// Blit's transfer-strip extension is left out, the messages name Nib, and a Trash Nib can't
// look into (~/.Trash, closed to apps without Full Disk Access) is told apart from an empty one.
//
// Emptying the Trash, to get space back (deleted files keep their space until then). Each
// drive other than the startup disk keeps its own Trash at /Volumes/<drive>/.Trashes/<uid>,
// which Nib empties directly: that drive only, no permission needed. The Mac's own Trash (and
// every drive's at once) is emptied by Finder over Apple Events, as Finder › Empty Trash does,
// and macOS asks once whether Nib may. Every empty asks first: it's the one permanent action.

import AppKit
import Foundation

@MainActor
enum TrashService {
    /// What's in a Trash: top-level items and their allocated bytes.
    struct Contents: Sendable, Equatable {
        var items: Int
        var bytes: Int64
        var isEmpty: Bool { items == 0 }
    }

    /// The Trash folder for the drive holding `url`, or nil for the startup disk (its Trash is
    /// ~/.Trash, emptied through Finder) and network shares (their deletes don't go to a Trash here).
    nonisolated static func volumeTrash(containing url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey])
        guard let volume = values?.volume, values?.volumeIsRootFileSystem != true, values?.volumeIsLocal != false,
              volume.path != "/" else { return nil }
        return volume.appendingPathComponent(".Trashes").appendingPathComponent(String(getuid()))
    }

    /// The Mac's own Trash, ~/.Trash.
    nonisolated static var userTrash: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true) }

    /// The drive's name, for messages ("SSD").
    nonisolated static func volumeName(containing url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// Counts a Trash folder (off the main thread: it walks every file). Nil when Nib can't
    /// look inside it (~/.Trash without Full Disk Access): then Finder is asked, on a click.
    nonisolated static func contents(of trash: URL) async -> Contents? {
        await Task.detached {
            let fm = FileManager.default
            guard let top = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
                // No folder at all is an empty Trash; one Nib may not list, unknown.
                return fm.fileExists(atPath: trash.path) ? nil : Contents(items: 0, bytes: 0)
            }
            var bytes: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
            for item in top {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys)
                    while let file = walker?.nextObject() as? URL {
                        bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                    }
                } else {
                    bytes += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            }
            // Hidden bookkeeping files (.DS_Store) take no part in the count.
            return Contents(items: top.filter { !$0.lastPathComponent.hasPrefix(".") }.count, bytes: bytes)
        }.value
    }

    /// Permanently removes everything in a drive's Trash folder. Returns the items that
    /// couldn't be removed, with why.
    nonisolated static func erase(_ trash: URL) async -> [String] {
        await Task.detached {
            let fm = FileManager.default
            guard let top = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return [] }
            var problems: [String] = []
            for item in top {
                do { try fm.removeItem(at: item) } catch { problems.append("\(item.lastPathComponent): \((error as NSError).localizedDescription)") }
            }
            return problems
        }.value
    }

    /// Finder's own empty-trash sound.
    static func playEmptySound() {
        #if DEBUG
        if testAnswer != nil { return }
        #endif
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    #if DEBUG
    /// The scenarios answer the confirmation themselves (true: empty).
    static var testAnswer: Bool?
    #endif

    /// Asks before erasing. `what` names the Trash ("the Trash on “SSD”").
    static func confirm(_ what: String, _ contents: Contents?) -> Bool {
        #if DEBUG
        if let testAnswer { return testAnswer }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently erase the items in \(what)?"
        var detail = "You can't undo this."
        if let contents {
            let size = contents.bytes.formatted(.byteCount(style: .file))
            detail = "\(contents.items) item\(contents.items == 1 ? "" : "s"), \(size). " + detail
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Empty Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Empties Finder's Trash (every drive). Returns a problem, or nil.
    static func emptyFinderTrash() async -> String? {
        let result = await runFinder("tell application \"Finder\" to empty trash")
        guard let error = result.error else { return nil }
        if error.code == -1743 {
            return "Nib isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation, then try again."
        }
        return "Couldn't empty the Trash: \(error.message)"
    }

    /// Items in Finder's Trash (all drives), or nil if Finder can't be asked.
    static func finderTrashCount() async -> Int? {
        let result = await runFinder("tell application \"Finder\" to count items of trash")
        return result.error == nil ? result.value.flatMap { Int($0) } : nil
    }

    private struct ScriptResult: Sendable {
        var value: String?
        var error: (code: Int, message: String)?
    }

    /// Runs AppleScript off the main thread (Finder can take a while).
    private static func runFinder(_ source: String) async -> ScriptResult {
        await Task.detached {
            var info: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return ScriptResult(error: (0, "bad script")) }
            let output = script.executeAndReturnError(&info)
            if let info {
                let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (info[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
                return ScriptResult(error: (code, message))
            }
            return ScriptResult(value: output.stringValue)
        }.value
    }
}
