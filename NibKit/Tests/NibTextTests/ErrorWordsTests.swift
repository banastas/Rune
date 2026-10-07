// Errors in the HUD's few words (PRD W1, W5), not Cocoa's sentence uppercased with the file's
// name in it twice (the QA review's F17); and as sentences, names as they're written.

import Foundation
import Testing

@testable import NibText

@Suite struct ErrorWordsTests {
    @Test func commonErrors() {
        #expect(ErrorWords.hud(CocoaError(.fileWriteNoPermission)) == "PERMISSION DENIED")
        #expect(ErrorWords.hud(CocoaError(.fileWriteVolumeReadOnly)) == "DISK IS READ-ONLY")
        #expect(ErrorWords.hud(POSIXError(.ENOTDIR)) == "FOLDER IS GONE")
        #expect(ErrorWords.hud(POSIXError(.ENOSPC)) == "DISK FULL")
        // A Cocoa error with no words of its own here, over a POSIX one that has them.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
        #expect(ErrorWords.hud(wrapped) == "DISK IS READ-ONLY")
        // Anything else: its reason's first sentence.
        let other = NSError(domain: "Elsewhere", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something odd happened. Try again."])
        #expect(ErrorWords.hud(other) == "SOMETHING ODD HAPPENED")
    }

    @Test func sentences() {
        #expect(Alerts.sentence(ErrorWords.hud(CocoaError(.fileWriteNoPermission))) == "Permission denied.")
        #expect(Alerts.saveFailed("Notes.md", why: "DISK IS READ-ONLY").body.hasPrefix("Disk is read-only. Your text"))
        // Sublime's failures keep their names' capitals (the welcome window had "mariana" lowercased).
        let missing = SublimeImport.Failure.noScheme("Mariana").sentence
        #expect(missing.contains("“Mariana”") && missing.hasSuffix("so nothing was imported."))
        #expect(SublimeImport.Failure.noSublime.sentence == "Sublime Text isn't on this Mac, so there's nothing to import.")
    }
}
