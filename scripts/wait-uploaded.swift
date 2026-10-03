// Waits, for up to the given seconds, until iCloud has finished uploading a file: for
// scripts/run-m1-scenarios.sh, before each launch. Nib doesn't pause a file iCloud is still
// uploading (PRD §4.3: that crashed its file provider), so a scenario launched then opens the test
// file unheld and waits on iCloud (`merge` with no note, 2026-10-02 18:04: 100 s, then killed).
// Prints a line only when it waited a second or more, or gave up.
//   wait-uploaded <file> [seconds]
import Foundation

let path = CommandLine.arguments[1]
let limit = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 120 : 120

/// iCloud uploading it, or yet to, as `Document.waitForUpload` asks (a paused file doesn't upload).
func uploading() -> Bool {
    let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemIsSyncPausedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey]
    // A new NSURL each time: one keeps the resource values it was first asked for.
    let values = (try? NSURL(fileURLWithPath: path).resourceValues(forKeys: keys)) ?? [:]
    func flag(_ key: URLResourceKey) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    guard flag(.isUbiquitousItemKey), !flag(.ubiquitousItemIsSyncPausedKey) else { return false }
    return flag(.ubiquitousItemIsUploadingKey) || !flag(.ubiquitousItemIsUploadedKey)
}

let started = Date()
while uploading(), Date().timeIntervalSince(started) < limit { Thread.sleep(forTimeInterval: 0.25) }
let waited = Int(Date().timeIntervalSince(started).rounded())
if uploading() {
    print("    (iCloud still uploading the test file after \(waited) s: launched anyway)")
} else if waited >= 1 {
    print("    (waited \(waited) s for iCloud to finish uploading the test file)")
}
