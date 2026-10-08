// nib-launch-swiftui (M0 S2): the same measurement as nib-launch-appkit, with the
// SwiftUI App lifecycle (WindowGroup + NSViewRepresentable), as Blit is built.

import AppKit
import QuartzCore
import SwiftUI

func processStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let start = info.kp_proc.p_un.__p_starttime
    return Double(start.tv_sec) + Double(start.tv_usec) / 1e6
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
}

func scratchText() -> String {
    let line = "rsync deploy draft vendor invoice notes call review ship\n"
    return "# scratch\n\n" + String(repeating: line, count: 197 * 1024 / line.utf8.count)
}

/// Reports once it's in a window and that window has drawn.
final class ReportingScrollView: NSScrollView {
    var reported = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !reported else { return }
        reported = true
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        DispatchQueue.main.async {
            window.displayIfNeeded()
            CATransaction.flush()
            let shown = (Date().timeIntervalSince1970 - processStart()) * 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                print("LAUNCH swiftui · first window \(Int(shown.rounded())) ms after process start · idle footprint \(footprintMB()) MB")
                fflush(stdout)
                exit(0)
            }
        }
    }
}

struct Editor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ReportingScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView(usingTextLayoutManager: true)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = scratchText()
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}

@main
struct LaunchApp: App {
    init() { NSApplication.shared.setActivationPolicy(.accessory) }
    var body: some Scene {
        WindowGroup { Editor().frame(width: 800, height: 600) }
    }
}
