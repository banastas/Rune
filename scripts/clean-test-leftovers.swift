#!/usr/bin/env swift
// Clears what Nib's test runs left in the Nib in daily use's folder and settings, from before the
// test harness had a folder and settings of its own (2026-10-01, PRD §6.4), and old files in the
// iCloud test folder. Nothing is erased: it all goes into one folder, with a copy of the settings
// as they were, and that folder goes to the Trash, so it can be put back until the Trash is
// emptied. A dry run unless given --remove; it refuses while Nib runs.
//
//   swift scripts/clean-test-leftovers.swift            # says what it would move
//   swift scripts/clean-test-leftovers.swift --remove   # moves it to the Trash
//
// What counts as a test leftover (Nib has opened only test files so far: the safety rule, §8):
// History, journal files and per-file settings for files in iCloud Drive/Nib/Test, nib-spike,
// temporary folders, and untitled buffers; History of files no record names any more; the whole
// Sync Log; empty untitled-buffer folders; Open Recent's and Reopen Closed File's test entries; and
// everything in iCloud Drive/Nib/Test but the scenarios' scratch-test.md and its .nib folder.
// Kept: every other setting (window places, the first run done), a live untitled buffer's file,
// and any record of a file outside those places.

import AppKit
import CryptoKit
import Foundation

let remove = CommandLine.arguments.contains("--remove")
let fm = FileManager.default
let home = NSHomeDirectory()
let support = URL(fileURLWithPath: home + "/Library/Application Support/nib", isDirectory: true)
let testFolder = URL(fileURLWithPath: home + "/Library/Mobile Documents/iCloud~com~banastas~nib/Documents/Test", isDirectory: true)
let domain = "com.banastas.nib"

guard NSRunningApplication.runningApplications(withBundleIdentifier: domain).isEmpty else {
    print("Nib is running (or a test run is): quit it first, then run this again.")
    exit(1)
}

func isTest(_ path: String) -> Bool {
    path.contains("/Mobile Documents/iCloud~com~banastas~nib/Documents/Test/")
        || path.contains("/Mobile Documents/com~apple~CloudDocs/nib-spike/")
        || path.contains("/Application Support/nib/Untitled/")
        || ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
}

/// How Nib names a file's History folder and journal: the first 20 hex digits of its path's SHA-256.
func key(_ path: String) -> String {
    String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(20))
}

func size(_ url: URL) -> Int64 {
    var total: Int64 = 0
    if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
        for case let file as URL in walker { total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
    }
    return total + Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

// Every path Nib has a record of: the Sync Log, the per-file settings, Open Recent, Reopen Closed File.
let settings = UserDefaults(suiteName: domain)?.persistentDomain(forName: domain) ?? [:]
var paths = Set<String>()
let syncLog = support.appendingPathComponent("sync.jsonl")
if let text = try? String(contentsOf: syncLog, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        if let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = event["path"] as? String {
            paths.insert(path)
        }
    }
}
let perFile = ["selection:", "syntax:", "siblings:"]
for name in settings.keys { for prefix in perFile where name.hasPrefix(prefix) { paths.insert(String(name.dropFirst(prefix.count))) } }
let recent = settings["recentFiles"] as? [String] ?? []
paths.formUnion(recent)
let closed = (settings["recentlyClosed"] as? Data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
paths.formUnion(closed.compactMap { $0["path"] as? String })
let byKey = Dictionary(paths.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })

// What would go.
var moves: [(from: URL, to: String)] = []   // `to`: its place in the leftovers folder
var notes: [String] = []

let historyFolders = (try? fm.contentsOfDirectory(atPath: support.appendingPathComponent("History").path)) ?? []
var historyTest = 0, historyUnnamed = 0, historyKept: [String] = [], historyBytes: Int64 = 0, recentScratch = 0
let scratchKey = key(testFolder.appendingPathComponent("scratch-test.md").path)
for folder in historyFolders where !folder.hasPrefix(".") {
    let url = support.appendingPathComponent("History").appendingPathComponent(folder)
    if let path = byKey[folder] {
        guard isTest(path) else { historyKept.append(path); continue }
        historyTest += 1
    } else {
        historyUnnamed += 1   // a file no record names any more: under the safety rule, a test file
    }
    if folder == scratchKey, let index = try? String(contentsOf: url.appendingPathComponent("index.jsonl"), encoding: .utf8) {
        let recentLimit = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86_400))
        recentScratch = index.split(separator: "\n").filter { line in
            guard let data = line.data(using: .utf8), let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let time = entry["time"] as? String else { return false }
            return time >= recentLimit
        }.count
    }
    historyBytes += size(url)
    moves.append((url, "History/" + folder))
}
notes.append("History: \(historyTest + historyUnnamed) of \(historyFolders.count) folders, \(bytes(historyBytes)) (\(historyTest) for test files and untitled buffers, \(historyUnnamed) for files no record names any more)"
             + (historyKept.isEmpty ? "" : "; kept \(historyKept.count), for other files"))
if recentScratch > 0 {
    notes.append("  NOTE: \(recentScratch) of those are versions of the test scratch file from the last 2 days (a day test's?). If you typed anything there you want, copy it out first (Nib's History window on that file), or put it back from the Trash after.")
}

if fm.fileExists(atPath: syncLog.path) {
    moves.append((syncLog, "sync.jsonl"))
    notes.append("The Sync Log, \(bytes(size(syncLog))): everything in it is test runs")
}

let journal = support.appendingPathComponent("Journal")
var journalCount = 0, journalKept = 0
for file in (try? fm.contentsOfDirectory(atPath: journal.path)) ?? [] where !file.hasPrefix(".") {
    let name = (file as NSString).deletingPathExtension
    if let path = byKey[name], isTest(path) {
        moves.append((journal.appendingPathComponent(file), "Journal/" + file))
        journalCount += 1
    } else {
        journalKept += 1
    }
}
notes.append("Journal: \(journalCount) files for test files" + (journalKept > 0 ? "; kept \(journalKept) (other files, or not known)" : ""))

let untitled = support.appendingPathComponent("Untitled")
var emptyUntitled = 0, liveUntitled = 0
for folder in (try? fm.contentsOfDirectory(atPath: untitled.path)) ?? [] where !folder.hasPrefix(".") {
    let url = untitled.appendingPathComponent(folder)
    let inside = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
    if inside.isEmpty { moves.append((url, "Untitled/" + folder)); emptyUntitled += 1 } else { liveUntitled += 1 }
}
notes.append("Untitled: \(emptyUntitled) empty folders" + (liveUntitled > 0 ? "; kept \(liveUntitled) holding an untitled buffer still open" : ""))

let settingKeys = settings.keys.filter { name in perFile.contains { name.hasPrefix($0) && isTest(String(name.dropFirst($0.count))) } }
let recentLeft = recent.filter { !isTest($0) }
let closedLeft = closed.filter { item in !(item["untitled"] as? Bool ?? false) && !isTest(item["path"] as? String ?? "") }
notes.append("Settings: \(settingKeys.count) per-file entries for test files, temporary files and untitled buffers; Open Recent \(recent.count - recentLeft.count) of \(recent.count); Reopen Closed File \(closed.count - closedLeft.count) of \(closed.count)")

var oldTestFiles: [URL] = []
for name in (try? fm.contentsOfDirectory(atPath: testFolder.path)) ?? [] where name != "scratch-test.md" && name != ".nib" && !name.hasPrefix("old-test-files-") {
    oldTestFiles.append(testFolder.appendingPathComponent(name))
}
notes.append("iCloud Drive/Nib/Test: \(oldTestFiles.count) old entries (kept: scratch-test.md and .nib); this folder syncs, so they go on the other Mac too")

print(remove ? "Moving to the Trash:" : "Would move to the Trash (a dry run; --remove to do it):")
for note in notes { print("  " + note) }
guard remove else { exit(0) }
let settingsChange = !settingKeys.isEmpty || recentLeft.count != recent.count || closedLeft.count != closed.count

// Into one folder, the settings as they were with them; then that folder to the Trash.
let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
let leftovers = support.deletingLastPathComponent().appendingPathComponent("Nib test leftovers \(stamp)", isDirectory: true)
if moves.isEmpty, !settingsChange {
    // Nothing of Nib's own folder or settings to move: no folder for it.
} else {
do {
    try fm.createDirectory(at: leftovers, withIntermediateDirectories: true)
    let copy = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
    try copy.write(to: leftovers.appendingPathComponent("settings before (defaults import \(domain) this-file).plist"))
    for (from, to) in moves {
        let target = leftovers.appendingPathComponent(to)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: target)
    }
} catch {
    print("Stopped: \(error.localizedDescription). What moved so far is in \(leftovers.path); nothing was erased.")
    exit(1)
}

}

// The settings, only those entries (the store writes through cfprefsd, as Nib's own does).
if settingsChange, let store = UserDefaults(suiteName: domain) {
    for name in settingKeys { store.removeObject(forKey: name) }
    if recentLeft.count != recent.count { recentLeft.isEmpty ? store.removeObject(forKey: "recentFiles") : store.set(recentLeft, forKey: "recentFiles") }
    if closedLeft.count != closed.count {
        if closedLeft.isEmpty { store.removeObject(forKey: "recentlyClosed") }
        else if let data = try? JSONSerialization.data(withJSONObject: closedLeft) { store.set(data, forKey: "recentlyClosed") }
    }
    store.synchronize()
}

// The iCloud test folder's old files: gathered in one folder there, which goes to the Trash.
if !oldTestFiles.isEmpty {
    let old = testFolder.appendingPathComponent("old-test-files-\(stamp)", isDirectory: true)
    do {
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        for file in oldTestFiles { try fm.moveItem(at: file, to: old.appendingPathComponent(file.lastPathComponent)) }
        try fm.trashItem(at: old, resultingItemURL: nil)
    } catch {
        print("The iCloud test folder's old files: stopped at \(error.localizedDescription) (what moved is in \(old.path))")
    }
}

if fm.fileExists(atPath: leftovers.path) {
    do {
        var inTrash: NSURL?
        try fm.trashItem(at: leftovers, resultingItemURL: &inTrash)
        print("Done. In the Trash: “\(leftovers.lastPathComponent)”" + (oldTestFiles.isEmpty ? "" : " and “old-test-files-\(stamp)”") + ".")
        print("To put the settings back: defaults import \(domain) <the .plist in that folder>.")
    } catch {
        print("Gathered in \(leftovers.path), but couldn't move it to the Trash: \(error.localizedDescription)")
    }
} else {
    print(oldTestFiles.isEmpty ? "Nothing to move." : "Done. In the Trash: “old-test-files-\(stamp)”.")
}
