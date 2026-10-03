// What Nib writes to this Mac's disk, by writer (PRD §8, the disk-writes report of 2026-10-02).
// macOS counts the logical writes of each app and of what it launches (a resource coalition) and
// reports a day's worth over its limit (2-8 GB). The kernel counts a write as it's made, a small
// one as a whole 16 KB page and the file's metadata besides: a 100-byte line appended costs about
// 17 KB, written into room the file already has about 2 KB. While counting (the `writes`
// scenario), each of Nib's writers adds what it wrote and the kernel's count for this process
// around it, so a measurement can put the total down to the code that wrote it. Off, it costs a
// check.

import Darwin
import Synchronization

public enum WriteMeter {
    public struct Tally: Sendable, Equatable {
        public var writes = 0
        /// Bytes handed to the file system.
        public var bytes = 0
        /// The kernel's logical writes for this process while those writes ran: what the
        /// disk-writes limit counts. Another thread's writes at the same moment count here too.
        public var logical: UInt64 = 0
    }

    private static let state = Mutex<(counting: Bool, tallies: [String: Tally])>((false, [:]))

    public static var counting: Bool {
        get { state.withLock { $0.counting } }
        set { state.withLock { $0.counting = newValue } }
    }

    /// Before a write: the kernel's count now, or nil when not counting.
    public static func start() -> UInt64? {
        counting ? usage().logical : nil
    }

    /// After it: `bytes` written as `kind` ("file", "journal log"…), since `start`.
    public static func add(_ kind: String, bytes: Int, since start: UInt64?) {
        guard let start else { return }
        let logical = usage().logical &- start
        state.withLock {
            guard $0.counting else { return }
            $0.tallies[kind, default: Tally()].writes += 1
            $0.tallies[kind, default: Tally()].bytes += bytes
            $0.tallies[kind, default: Tally()].logical += logical
        }
    }

    /// What's been counted since the last call, and the count started over.
    public static func take() -> [String: Tally] {
        state.withLock { state in
            defer { state.tallies = [:] }
            return state.tallies
        }
    }

    /// This process's logical writes (the disk-writes report's measure), bytes written to disk,
    /// and its memory footprint now and at its highest, from `proc_pid_rusage`.
    public static func usage() -> (logical: UInt64, disk: UInt64, footprint: UInt64, peak: UInt64) {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard status == 0 else { return (0, 0, 0, 0) }
        return (info.ri_logical_writes, info.ri_diskio_byteswritten, info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    }
}
