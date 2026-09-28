// Every open file's Document (PRD ED2): one per file, so opening a file again brings its
// window forward rather than a second buffer. The scratch file is one of them and stays
// open with or without its window (SC1); a file's document lives as long as its window.

import AppKit
import NibSync

@MainActor
enum Documents {
    static let scratch = Document(url: ScratchLocation.url)
    private static var files: [String: Document] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// The scratch document and every file's.
    static var all: [Document] { [scratch] + files.values.sorted { $0.url.path < $1.url.path } }

    /// The file's document if it's open.
    static func existing(for url: URL) -> Document? {
        key(url) == key(scratch.url) ? scratch : files[key(url)]
    }

    /// The file's document, opened if it isn't yet.
    static func document(for url: URL) -> Document {
        if let open = existing(for: url) { return open }
        let document = Document(url: url)
        files[key(url)] = document
        Task { await document.open() }
        return document
    }

    /// Its window has closed: save, upload, hand the file back to iCloud, and forget it.
    static func close(_ document: Document) async {
        guard document !== scratch, files[key(document.url)] === document else { return }
        files[key(document.url)] = nil
        await document.close()
    }
}
