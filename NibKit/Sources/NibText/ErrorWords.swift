// Errors in a few of the HUD's words (PRD W1, W5, §5.13): the common file errors by their code,
// not Cocoa's whole sentence uppercased, which named the file twice and filled the strip
// ("COULDN'T SAVE SCRATCH.MD · YOU DON'T HAVE PERMISSION TO SAVE THE FILE “SCRATCH.MD” IN THE
// FOLDER “NIB”", the QA review's F17). `Alerts.sentence` makes a sentence of them.

import Foundation

public enum ErrorWords {
    /// "PERMISSION DENIED", "DISK IS READ-ONLY", "FILE IS GONE"…; for an error with no words of
    /// its own here, its reason's first sentence, uppercased.
    public static func hud(_ error: Error) -> String {
        let ns = error as NSError
        if let words = words(domain: ns.domain, code: ns.code) { return words }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, let words = words(domain: underlying.domain, code: underlying.code) {
            return words
        }
        let said = ns.localizedFailureReason ?? ns.localizedDescription
        let first = said.components(separatedBy: ". ").first ?? said
        return first.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).uppercased()
    }

    static func words(domain: String, code: Int) -> String? {
        switch domain {
        case NSCocoaErrorDomain:
            switch code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "PERMISSION DENIED"
            case NSFileWriteVolumeReadOnlyError: return "DISK IS READ-ONLY"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "FILE IS GONE"
            case NSFileWriteOutOfSpaceError: return "DISK FULL"
            case NSFileLockingError: return "FILE IS LOCKED"
            case NSFileReadCorruptFileError: return "FILE IS DAMAGED"
            case NSFileReadUnknownStringEncodingError, NSFileReadInapplicableStringEncodingError: return "UNKNOWN TEXT ENCODING"
            case NSFileWriteInapplicableStringEncodingError: return "CAN'T BE SAVED IN ITS ENCODING"
            case NSFileReadTooLargeError: return "FILE IS TOO LARGE"
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case EACCES, EPERM: return "PERMISSION DENIED"
            case EROFS: return "DISK IS READ-ONLY"
            case ENOENT: return "FILE IS GONE"
            case ENOTDIR: return "FOLDER IS GONE"
            case ENOSPC, EDQUOT: return "DISK FULL"
            case EBUSY: return "FILE IS BUSY"
            case ETIMEDOUT: return "TIMED OUT"
            case EIO: return "DISK ERROR"
            default: return nil
            }
        default: return nil
        }
    }
}
