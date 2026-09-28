// nib-spike (M0 S1): what iCloud Drive does for a plain file on macOS 27.
// Every mode works only on generated files inside iCloud Drive/nib-spike/
// (PRD §8 safety rule: nothing here ever opens the live scratch file).

import Darwin
import Foundation

// MARK: - Basics

let fm = FileManager.default
let spikeDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/nib-spike")
let host = Host.current().localizedName ?? "this Mac"
var arguments = Array(CommandLine.arguments.dropFirst())

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func log(_ text: String) {
    print("\(clock.string(from: Date())) \(text)")
    fflush(stdout)
}

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("nib-spike: \(text)\n".utf8))
    exit(1)
}

func ms(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }

func option(_ name: String, _ fallback: String) -> String {
    guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return fallback }
    return arguments[i + 1]
}

/// "1k", "200k", "2.4m" → bytes.
func bytes(_ text: String) -> Int {
    let lower = text.lowercased()
    let unit: Double = lower.hasSuffix("m") ? 1_048_576 : lower.hasSuffix("k") ? 1024 : 1
    let number = Double(lower.trimmingCharacters(in: CharacterSet(charactersIn: "km"))) ?? 0
    return Int(number * unit)
}

/// Refuses any path outside iCloud Drive/nib-spike/.
func checked(_ url: URL) -> URL {
    let url = url.standardizedFileURL
    guard url.path.hasPrefix(spikeDir.path + "/") else { fail("refusing \(url.path): outside \(spikeDir.path)") }
    return url
}

func spikeFile(_ name: String) -> URL { checked(spikeDir.appendingPathComponent(name)) }

func describe(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "ok" }
    var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        text += " ← \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
    }
    return text
}

func describe(_ version: NSFileVersion?) -> String {
    guard let v = version else { return "no version" }
    let when = v.modificationDate.map { clock.string(from: $0) } ?? "?"
    return "version saved \(when) by \(v.localizedNameOfSavingComputer ?? "?") at \(v.url.lastPathComponent)"
        + (v.isConflict ? " (conflict)" : "")
}

/// Generated Markdown shaped like a scratch file (about 48 bytes a line, headings, code fences).
func generatedText(bytes target: Int, seed: Int = 1) -> String {
    let words = ["deploy", "ssh", "draft", "vendor", "invoice", "rsync", "build", "notes", "call", "review",
                 "ship", "tuesday", "queue", "server", "hash", "reply", "thanks", "follow", "up", "check"]
    var state = seed
    func next() -> Int { state = (state &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff; return state }
    var text = "# nib spike file\n\n"
    var line = 0
    while text.utf8.count < target {
        line += 1
        switch line % 40 {
        case 0: text += "\n## Section \(line / 40)\n\n"
        case 7: text += "```bash\nrsync -av ~/src/ host:/srv/\(next() % 999)/\n```\n"
        default: text += (0..<(4 + next() % 9)).map { _ in words[next() % words.count] }.joined(separator: " ") + "\n"
        }
    }
    return text
}

// MARK: - iCloud state

struct CloudState: Equatable, CustomStringConvertible {
    var ubiquitous = false, uploading = false, uploaded = false, downloading = false
    var status = "?", conflicts = false, paused: Bool?, controls: Int?
    var uploadError: String?, downloadError: String?

    var description: String {
        var parts = [ubiquitous ? "ubiquitous" : "NOT ubiquitous", "status=\(status)",
                     uploading ? "UPLOADING" : "-", uploaded ? "UPLOADED" : "not-uploaded"]
        if downloading { parts.append("DOWNLOADING") }
        if conflicts { parts.append("CONFLICTS") }
        if let paused { parts.append(paused ? "SYNC-PAUSED" : "sync-running") }
        if let controls { parts.append("controls=\(controlNames(controls))") }
        if let uploadError { parts.append("upload-error=\(uploadError)") }
        if let downloadError { parts.append("download-error=\(downloadError)") }
        return parts.joined(separator: " ")
    }
}

func controlNames(_ raw: Int) -> String {
    var names: [String] = []
    if raw & 1 != 0 { names.append("pauseSync") }
    if raw & 2 != 0 { names.append("failUploadOnConflict") }
    return names.isEmpty ? "none" : names.joined(separator: "+")
}

/// A fresh NSURL each time, so no resource values come from a cache.
func cloudState(_ url: URL) -> CloudState {
    let keys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSyncPausedKey,
        .ubiquitousItemSupportedSyncControlsKey, .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemDownloadingErrorKey,
    ]
    let values = (try? NSURL(fileURLWithPath: url.path).resourceValues(forKeys: keys)) ?? [:]
    func flag(_ key: URLResourceKey) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    var state = CloudState()
    state.ubiquitous = flag(.isUbiquitousItemKey)
    state.uploading = flag(.ubiquitousItemIsUploadingKey)
    state.uploaded = flag(.ubiquitousItemIsUploadedKey)
    state.downloading = flag(.ubiquitousItemIsDownloadingKey)
    state.conflicts = flag(.ubiquitousItemHasUnresolvedConflictsKey)
    state.paused = (values[.ubiquitousItemIsSyncPausedKey] as? NSNumber)?.boolValue
    state.controls = (values[.ubiquitousItemSupportedSyncControlsKey] as? NSNumber)?.intValue
    switch values[.ubiquitousItemDownloadingStatusKey] as? String {
    case URLUbiquitousItemDownloadingStatus.current.rawValue: state.status = "current"
    case URLUbiquitousItemDownloadingStatus.downloaded.rawValue: state.status = "stale"
    case URLUbiquitousItemDownloadingStatus.notDownloaded.rawValue: state.status = "notDownloaded"
    case let other?: state.status = other
    case nil: state.status = "none"
    }
    state.uploadError = (values[.ubiquitousItemUploadingErrorKey] as? NSError).map { describe($0) }
    state.downloadError = (values[.ubiquitousItemDownloadingErrorKey] as? NSError).map { describe($0) }
    return state
}

/// Polls every `every` seconds, logging each change, until `done` or the timeout. Returns ms taken.
@discardableResult
func watch(_ url: URL, timeout: TimeInterval, every: TimeInterval = 0.1, _ label: String,
           until done: (CloudState) -> Bool) -> Int? {
    let start = Date()
    var last: CloudState?
    while Date().timeIntervalSince(start) < timeout {
        let state = cloudState(url)
        if state != last { log("  +\(ms(since: start)) ms  \(state)"); last = state }
        if done(state) { return ms(since: start) }
        Thread.sleep(forTimeInterval: every)
    }
    log("  gave up after \(Int(timeout)) s waiting for \(label)")
    return nil
}

// MARK: - File access

func coordinatedWrite(_ text: String, to url: URL) throws {
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
        do { try Data(text.utf8).write(to: target, options: .atomic) } catch { writeError = error }
    }
    if let error = coordinationError ?? writeError { throw error }
}

/// The ways a save can land on disk. `atomic` makes a new file and renames it over the
/// old one (a new inode); `inplace` truncates and rewrites the same file; `replace`
/// writes a temp file and swaps it in with FileManager.replaceItemAt.
func save(_ text: String, to url: URL, how: String) throws {
    switch how {
    case "inplace":
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            do {
                let handle = try FileHandle(forWritingTo: target)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data(text.utf8))
                try handle.synchronize()
                try handle.close()
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    case "replace":
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                let temp = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                    .appendingPathComponent(target.lastPathComponent)
                try Data(text.utf8).write(to: temp)
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    default:
        try coordinatedWrite(text, to: url)
    }
}

func inode(_ url: URL) -> UInt64 {
    var info = stat()
    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
}

func coordinatedRead(_ url: URL) throws -> String {
    var coordinationError: NSError?
    var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
        result = Result { try String(contentsOf: target, encoding: .utf8) }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
}

func xattrs(_ url: URL) -> [String] {
    let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    guard size > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: size)
    listxattr(url.path, &buffer, size, XATTR_NOFOLLOW)
    return buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
}

func setXattr(_ name: String, _ value: String, on url: URL) {
    let data = Array(value.utf8)
    if setxattr(url.path, name, data, data.count, 0, XATTR_NOFOLLOW) != 0 { log("  setxattr \(name) failed: errno \(errno)") }
}

func statLine(_ url: URL) -> String {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return "stat failed: errno \(errno)" }
    let dataless = info.st_flags & 0x4000_0000 != 0   // SF_DATALESS
    return "size \(info.st_size) · blocks \(info.st_blocks)" + (dataless ? " · DATALESS" : "")
}

/// Waits on a completion-handler API from the (blocking) main thread.
func blocking<T>(_ label: String, _ body: (@escaping (T?, Error?) -> Void) -> Void) -> (T?, Error?) {
    let done = DispatchSemaphore(value: 0)
    var value: T?
    var failure: Error?
    let start = Date()
    body { v, e in value = v; failure = e; done.signal() }
    if done.wait(timeout: .now() + 120) == .timedOut { log("  \(label): no answer in 120 s"); return (nil, nil) }
    log("  \(label): \(ms(since: start)) ms · \(describe(failure))")
    return (value, failure)
}

func pause(_ url: URL) -> Error? {
    blocking("pauseSync") { (finish: @escaping (Bool?, Error?) -> Void) in
        fm.pauseSyncForUbiquitousItem(at: url) { finish(true, $0) }
    }.1
}

func resume(_ url: URL, _ behavior: NSFileManagerResumeSyncBehavior = .preserveLocalChanges) -> Error? {
    blocking("resumeSync") { (finish: @escaping (Bool?, Error?) -> Void) in
        fm.resumeSyncForUbiquitousItem(at: url, with: behavior) { finish(true, $0) }
    }.1
}

func uploadNow(_ url: URL) -> (NSFileVersion?, Error?) {
    blocking("uploadLocalVersion(failOnConflict)") { finish in
        fm.uploadLocalVersionOfUbiquitousItem(at: url, withConflictResolutionPolicy: .conflictPolicyFailOnConflict, completionHandler: finish)
    }
}

func fetchLatest(_ url: URL) -> (NSFileVersion?, Error?) {
    blocking("fetchLatestRemoteVersion") { finish in
        fm.fetchLatestRemoteVersionOfItem(at: url, completionHandler: finish)
    }
}

/// A new generated file, written with coordination, then left to iCloud.
func makeFile(_ prefix: String, size: Int) -> URL {
    try? fm.createDirectory(at: spikeDir, withIntermediateDirectories: true)
    let stampName = DateFormatter()
    stampName.dateFormat = "HHmmss"
    let url = spikeFile("\(prefix)-\(size / 1024)k-\(stampName.string(from: Date())).md")
    do { try coordinatedWrite(generatedText(bytes: size), to: url) } catch { fail("write failed: \(describe(error))") }
    log("wrote \(url.lastPathComponent) (\(size) bytes)")
    return url
}

func waitUploaded(_ url: URL, timeout: TimeInterval = 300) -> Int? {
    watch(url, timeout: timeout, "upload") { $0.uploaded && !$0.uploading }
}

// MARK: - Modes

func modeStatus() {
    let files = (try? fm.contentsOfDirectory(at: spikeDir, includingPropertiesForKeys: nil)) ?? []
    log("\(files.count) item(s) in \(spikeDir.path) on \(host)")
    for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        log("\(url.lastPathComponent): \(cloudState(url))")
        log("  \(statLine(url)) · xattrs: \(xattrs(url).joined(separator: ", "))")
    }
}

func modeUpload() {
    let url = makeFile("upload", size: bytes(option("size", "200k")))
    if let t = waitUploaded(url) { log("RESULT upload \(option("size", "200k")): uploaded \(t) ms after the write") }
}

func modeTyping() {
    let size = bytes(option("size", "200k"))
    let every = Double(option("every", "1")) ?? 1
    let count = Int(option("count", "20")) ?? 20
    let url = makeFile("typing", size: size)
    _ = waitUploaded(url)
    var text = generatedText(bytes: size)
    var results: [String] = []
    for n in 1...count {
        text += "- save \(n) at \(clock.string(from: Date()))\n"
        let written = Date()
        try? coordinatedWrite(text, to: url)
        var uploadedAfter: Int?
        while Date().timeIntervalSince(written) < every {
            let state = cloudState(url)
            if uploadedAfter == nil, state.uploaded, !state.uploading { uploadedAfter = ms(since: written) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        results.append(uploadedAfter.map { "\($0) ms" } ?? "not before next save")
        log("save \(n): uploaded \(results.last!)")
    }
    let final = waitUploaded(url)
    log("RESULT typing \(option("size", "200k")) every \(every) s × \(count): per save [\(results.joined(separator: ", "))]; last save uploaded \(final.map { "\($0) ms" } ?? "never") after the loop ended")
}

/// Continuous typing with nib's intended pipeline: sync paused, a save in place every
/// `every` seconds, and "upload now" (fail on conflict) at most every `upload-every` seconds.
func modePushTyping() {
    let size = bytes(option("size", "200k"))
    let every = Double(option("every", "1")) ?? 1
    let count = Int(option("count", "20")) ?? 20
    let uploadEvery = Double(option("upload-every", "3")) ?? 3
    let url = makeFile("push", size: size)
    _ = waitUploaded(url)
    var paused = false
    for attempt in 1...10 where !paused {
        paused = pause(url) == nil
        if !paused { Thread.sleep(forTimeInterval: Double(attempt) * 0.5) }
    }
    guard paused else { fail("could not pause") }
    var text = generatedText(bytes: size)
    let lock = NSLock()
    var inFlight = false
    var lastUploadStart = Date.distantPast
    var uploads: [String] = []
    let loopStart = Date()
    for n in 1...count {
        let tick = Date()
        text += "- save \(n) at \(clock.string(from: tick))\n"
        do { try save(text, to: url, how: "inplace") } catch { log("save \(n) failed: \(describe(error))") }
        lock.lock()
        let start = !inFlight && tick.timeIntervalSince(lastUploadStart) >= uploadEvery
        if start { inFlight = true; lastUploadStart = tick }
        lock.unlock()
        if start {
            let savedAt = n
            fm.uploadLocalVersionOfUbiquitousItem(at: url, withConflictResolutionPolicy: .conflictPolicyFailOnConflict) { _, error in
                let line = "upload of save \(savedAt): \(ms(since: tick)) ms · \(describe(error))"
                log("  " + line)
                lock.lock(); uploads.append(line); inFlight = false; lock.unlock()
            }
        }
        Thread.sleep(forTimeInterval: max(0, every - Date().timeIntervalSince(tick)))
    }
    while true { lock.lock(); let busy = inFlight; lock.unlock(); if !busy { break }; Thread.sleep(forTimeInterval: 0.1) }
    let final = uploadNow(url)
    _ = resume(url)
    log("RESULT push-typing \(option("size", "200k")) · save every \(every) s × \(count) (\(ms(since: loopStart)) ms) · upload at most every \(uploadEvery) s: \(uploads.count) uploads during typing, final upload \(describe(final.1))")
}

func modeControls() {
    let url = makeFile("controls", size: bytes(option("size", "200k")))
    _ = waitUploaded(url)
    log("before: \(cloudState(url))")
    let paused = pause(url) == nil
    log("after pause: \(cloudState(url))")
    let how = option("write", "inplace")
    let before = inode(url)
    do { try save(generatedText(bytes: bytes(option("size", "200k"))) + "- edited while paused\n", to: url, how: how) }
    catch { log("  \(how) write failed: \(describe(error))") }
    log("  \(how) write: inode \(before) → \(inode(url))")
    Thread.sleep(forTimeInterval: 3)
    log("3 s after a write while paused: \(cloudState(url))")
    let (uploaded, _) = uploadNow(url)
    log("  uploaded: \(describe(uploaded))")
    log("after upload: \(cloudState(url))")
    let (latest, _) = fetchLatest(url)
    log("  latest: \(describe(latest))")
    if paused { _ = resume(url) }
    log("after resume: \(cloudState(url))")
    _ = waitUploaded(url, timeout: 60)
    log("RESULT controls: see the pause, upload, fetch and resume lines above")
}

func modeEvict() {
    let url = makeFile("evict", size: bytes(option("size", "200k")))
    setXattr("com.banastas.nib.lineage#S", "lineage-from-\(host)", on: url)
    setXattr("com.banastas.nib.local", "plain-from-\(host)", on: url)
    log("xattrs before: \(xattrs(url).joined(separator: ", "))")
    _ = waitUploaded(url)
    let start = Date()
    do { try fm.evictUbiquitousItem(at: url) } catch { log("evict failed: \(describe(error))") }
    log("evictUbiquitousItem returned after \(ms(since: start)) ms")
    watch(url, timeout: 60, "eviction") { $0.status == "notDownloaded" }
    log("evicted: \(statLine(url)) · xattrs: \(xattrs(url).joined(separator: ", "))")
    // Reading a dataless file: does it block until the download finishes?
    let readStart = Date()
    let text = try? coordinatedRead(url)
    log("coordinated read of the evicted file returned \(text?.utf8.count ?? -1) bytes after \(ms(since: readStart)) ms")
    log("after read: \(cloudState(url)) · \(statLine(url)) · xattrs: \(xattrs(url).joined(separator: ", "))")
    // Evict again, then download explicitly.
    try? fm.evictUbiquitousItem(at: url)
    watch(url, timeout: 60, "second eviction") { $0.status == "notDownloaded" }
    let downloadStart = Date()
    do { try fm.startDownloadingUbiquitousItem(at: url) } catch { log("startDownloading failed: \(describe(error))") }
    watch(url, timeout: 120, "download") { $0.status == "current" }
    log("RESULT evict: read took \(ms(since: readStart)) ms incl. later steps; explicit download reached current \(ms(since: downloadStart)) ms after the request; xattrs now: \(xattrs(url).joined(separator: ", "))")
}

final class Presenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    var mark = Date()
    init(_ url: URL) { presentedItemURL = url }
    func note(_ what: String) { log("  presenter: \(what) (+\(ms(since: mark)) ms)") }
    func presentedItemDidChange() { note("presentedItemDidChange") }
    func presentedItemDidGain(_ version: NSFileVersion) { note("didGain \(describe(version))") }
    func presentedItemDidLose(_ version: NSFileVersion) { note("didLose \(describe(version))") }
    func presentedItemDidResolveConflict(_ version: NSFileVersion) { note("didResolveConflict") }
    func presentedItemDidMove(to newURL: URL) { note("didMove to \(newURL.lastPathComponent)") }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) { note("deletion"); completionHandler(nil) }
    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) {
        note("ubiquity attributes changed: \(attributes.map(\.rawValue).sorted().joined(separator: ", "))")
    }
    var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> {
        [.ubiquitousItemIsUploadingKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey,
         .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsSyncPausedKey]
    }
}

func modePresenter() {
    let url = makeFile("presenter", size: bytes(option("size", "20k")))
    _ = waitUploaded(url, timeout: 120)
    let presenter = Presenter(url)
    NSFileCoordinator.addFilePresenter(presenter)
    // The parent folder, for writers that don't coordinate.
    let folder = open(spikeDir.path, O_EVTONLY)
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folder, eventMask: [.write, .rename, .delete], queue: .global())
    source.setEventHandler { log("  folder event \(source.data) (+\(ms(since: presenter.mark)) ms)") }
    source.resume()
    Thread.sleep(forTimeInterval: 1)

    log("A · coordinated atomic write from this process")
    presenter.mark = Date()
    try? coordinatedWrite(generatedText(bytes: 20_000, seed: 2), to: url)
    Thread.sleep(forTimeInterval: 3)

    log("B · uncoordinated append from another process (like `echo >> file`)")
    presenter.mark = Date()
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "printf 'appended by sh\\n' >> \"$0\"", url.path]
    try? shell.run()
    shell.waitUntilExit()
    Thread.sleep(forTimeInterval: 3)

    log("C · watching iCloud attributes while the upload runs")
    presenter.mark = Date()
    _ = waitUploaded(url, timeout: 60)
    Thread.sleep(forTimeInterval: 2)
    NSFileCoordinator.removeFilePresenter(presenter)
    source.cancel()
    log("RESULT presenter: see the presenter and folder lines after A, B and C")
}

func modeMetadata() {
    let scopes: [(String, String)] = [
        ("UbiquitousDocuments", NSMetadataQueryUbiquitousDocumentsScope),
        ("UbiquitousData", NSMetadataQueryUbiquitousDataScope),
        ("AccessibleUbiquitousExternalDocuments", NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope),
    ]
    for (name, scope) in scopes {
        let query = NSMetadataQuery()
        query.searchScopes = [scope]
        query.predicate = NSPredicate(format: "%K LIKE '*.md'", NSMetadataItemFSNameKey)
        var gathered = false
        let token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil) { _ in gathered = true }
        let started = query.start()
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        query.stop()
        NotificationCenter.default.removeObserver(token)
        let paths = (0..<query.resultCount).compactMap { (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
        log("scope \(name): started=\(started) gathered=\(gathered) results=\(paths.count)" + (paths.first.map { " e.g. \($0)" } ?? ""))
    }
    log("RESULT metadata: without an iCloud entitlement, see which scopes return anything")
}

/// Two Macs: `writer` on one, `reader` on the other. Content carries the write time.
func modeWriter() {
    let every = Double(option("every", "5")) ?? 5
    let count = Int(option("count", "24")) ?? 24
    let push = option("mode", "plain") == "push"
    let url = spikeFile("latency.md")
    if push, fm.fileExists(atPath: url.path) { _ = pause(url) }
    for n in 1...count {
        let now = Date()
        let text = "seq \(n) written \(Int(now.timeIntervalSince1970 * 1000)) by \(host)\n"
        try? coordinatedWrite(text, to: url)
        if push { _ = uploadNow(url) }
        log("wrote seq \(n)")
        Thread.sleep(forTimeInterval: max(0, every - Date().timeIntervalSince(now)))
    }
    if push { _ = resume(url) }
    log("RESULT writer: \(count) writes every \(every) s (\(push ? "pause + upload now" : "plain writes"))")
}

func modeReader() {
    let seconds = Double(option("seconds", "150")) ?? 150
    let fetchEvery = Double(option("fetch-every", "0")) ?? 0
    let url = spikeFile("latency.md")
    let start = Date()
    var lastFetch = Date.distantPast
    var seen = 0
    var latencies: [Int] = []
    while Date().timeIntervalSince(start) < seconds {
        if fetchEvery > 0, Date().timeIntervalSince(lastFetch) >= fetchEvery {
            lastFetch = Date()
            fm.fetchLatestRemoteVersionOfItem(at: url) { _, error in if let error { log("  fetch: \(describe(error))") } }
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let parts = text.split(separator: " ")
            if parts.count >= 4, parts[0] == "seq", let n = Int(parts[1]), n > seen, let written = Double(parts[3]) {
                let latency = Int(Date().timeIntervalSince1970 * 1000 - written)
                seen = n
                latencies.append(latency)
                log("seq \(n) arrived \(latency) ms after it was written · \(cloudState(url))")
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    let sorted = latencies.sorted()
    func pct(_ p: Double) -> String { sorted.isEmpty ? "—" : "\(sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) ms" }
    log("RESULT reader: \(sorted.count) arrivals · p50 \(pct(0.5)) · p95 \(pct(0.95)) · max \(sorted.last.map { "\($0) ms" } ?? "—")")
}

/// Pause persists across crashes and relaunches, so this resumes anything left paused.
func modeCleanup() {
    let files = (try? fm.contentsOfDirectory(at: spikeDir, includingPropertiesForKeys: nil)) ?? []
    for url in files where cloudState(url).paused == true {
        log("\(url.lastPathComponent) was paused")
        _ = resume(url)
    }
    log("RESULT cleanup: nothing in nib-spike is paused now")
}

// MARK: - Main

let modes: [String: () -> Void] = [
    "status": modeStatus, "upload": modeUpload, "typing": modeTyping, "controls": modeControls,
    "evict": modeEvict, "presenter": modePresenter, "metadata": modeMetadata,
    "writer": modeWriter, "push-typing": modePushTyping, "reader": modeReader, "cleanup": modeCleanup,
]

guard let mode = arguments.first, let run = modes[mode] else {
    print("""
    usage: nib-spike <mode> [options]    (files only in iCloud Drive/nib-spike/)
      status                         iCloud state, flags and xattrs of every spike file
      upload   --size 200k           write a file, time until iCloud reports it uploaded
      typing   --size 200k --every 1 --count 20   repeated saves: does upload keep up?
      push-typing --size 200k --every 1 --count 20 --upload-every 3   paused, in-place saves, upload now
      controls --size 200k --write inplace|replace|atomic   pause, save, upload now (fail on conflict), fetch, resume
      evict    --size 200k           xattrs, eviction, reading a dataless file, explicit download
      presenter --size 20k           NSFilePresenter and folder events for three kinds of change
      metadata                       NSMetadataQuery scopes without an iCloud entitlement
      writer   --every 5 --count 24 --mode plain|push   two Macs: write latency.md (Mac A)
      reader   --seconds 150 --fetch-every 0           two Macs: log arrival times (Mac B)
      cleanup                        resume sync on anything left paused
    """)
    exit(arguments.isEmpty ? 0 : 2)
}
log("nib-spike \(mode) on \(host), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
run()
