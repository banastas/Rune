// What nib knows about a version of a file (PRD §4.3 step 4): cheap stat fields to
// notice a change, and the SHA-256 of the contents to tell whether it really is one.

import CryptoKit
import Foundation

public struct Fingerprint: Sendable, Codable, Equatable {
    public var size: Int64
    public var modified: TimeInterval
    public var fileID: UInt64
    /// Lowercase hex SHA-256 of the file's bytes, when read.
    public var sha256: String?

    public init(size: Int64, modified: TimeInterval, fileID: UInt64, sha256: String? = nil) {
        self.size = size
        self.modified = modified
        self.fileID = fileID
        self.sha256 = sha256
    }

    /// Same size, modification time and file: nothing to look at. A difference means
    /// the contents might differ; the SHA-256 decides.
    public func sameStat(as other: Fingerprint) -> Bool {
        size == other.size && modified == other.modified && fileID == other.fileID
    }
}

public enum Digest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    /// "9f3a1c…" for the strip and the log.
    public static func short(_ hex: String?) -> String { hex.map { String($0.prefix(6)) + "…" } ?? "—" }
}
