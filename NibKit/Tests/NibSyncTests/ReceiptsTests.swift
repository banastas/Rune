// Delivery receipts (PRD SY14): read back as written; another format ignored, not misread;
// device names as file names; updates that keep other entries and drop gone files; and each
// other Mac's version judged against this Mac's.

import Foundation
import Testing

@testable import NibSync

@Suite struct ReceiptsTests {
    let time = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func roundTripAndFormat() throws {
        let receipts = DeviceReceipts(device: "Bill's MacBook Air", files: ["scratch.md": .init(sha256: "abc", time: time)])
        #expect(DeviceReceipts.decode(try receipts.encoded()) == receipts)
        let future = try receipts.encoded()
        let later = String(decoding: future, as: UTF8.self).replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2")
        #expect(later != String(decoding: future, as: UTF8.self))   // the format was in it
        #expect(DeviceReceipts.decode(Data(later.utf8)) == nil)      // a later format: ignored
        #expect(DeviceReceipts.decode(Data("{\"device\":\"x\"}".utf8)) == nil)
    }

    @Test func fileNames() {
        let folder = URL(fileURLWithPath: "/tmp/Nib/.nib/devices")
        #expect(DeviceReceipts.url(in: folder, device: "Bill's MacBook Air").lastPathComponent == "Bill's MacBook Air.json")
        #expect(DeviceReceipts.url(in: folder, device: "a/b:c").lastPathComponent == "a-b-c.json")
        #expect(DeviceReceipts.url(in: folder, device: ".hidden").lastPathComponent == "-hidden.json")
        #expect(DeviceReceipts.folder(for: URL(fileURLWithPath: "/tmp/Nib/Test/scratch.md")).path == "/tmp/Nib/Test/.nib/devices")
    }

    @Test func updates() {
        let folder = URL(fileURLWithPath: "/tmp/Nib/.nib/devices")
        let old = DeviceReceipts(device: "Mini", files: [
            "kept.md": .init(sha256: "k", time: time),
            "gone.md": .init(sha256: "g", time: time),
            "stale.md": .init(sha256: "s", time: time.addingTimeInterval(-40 * 86_400)),
        ])
        let next = old.updated(with: ["new.md": .init(sha256: "n", time: time)], folder: folder, now: time) { $0.lastPathComponent != "gone.md" }
        #expect(next.files.keys.sorted() == ["kept.md", "new.md"])
        #expect(next.files["new.md"]?.sha256 == "n")
    }

    /// iCloud marks the files in `.nib` hidden: the other Macs' receipts are read all the same
    /// (the two-Mac test at 17:50 saw none), and this Mac's own isn't among them.
    @Test func hiddenReceiptsAreRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let air = DeviceReceipts(device: "Bill’s MacBook Air", files: ["scratch.md": .init(sha256: "a948", time: time)])
        let mini = DeviceReceipts(device: "m2pr0m4cm1n1", files: ["scratch.md": .init(sha256: "a948", time: time)])
        for receipts in [air, mini] {
            var url = DeviceReceipts.url(in: folder, device: receipts.device)
            try receipts.write(to: url)
            var values = URLResourceValues()
            values.isHidden = true
            try url.setResourceValues(values)
            #expect((try url.resourceValues(forKeys: [.isHiddenKey])).isHidden == true)
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent(".partial.json"))   // a dot: not a receipt
        let others = DeviceReceipts.others(in: folder, except: "m2pr0m4cm1n1")
        #expect(others == [air])
    }

    @Test func judged() {
        let seen: Set<String> = ["old", "merged"]
        #expect(Delivery.of("mine", base: "mine") { seen.contains($0) } == .same)
        #expect(Delivery.of("old", base: "mine") { seen.contains($0) } == .earlier)
        #expect(Delivery.of("unheard", base: "mine") { seen.contains($0) } == .newer)
    }
}
