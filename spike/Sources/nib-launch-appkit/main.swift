// nib-launch-appkit (M0 S2): process start to first window displayed, and idle
// memory 3 s later, with a plain AppKit lifecycle. The window holds an NSTextView
// (TextKit 2) with 197 KB of generated text, today's scratch size.

import AppKit
import QuartzCore

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

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window = NSWindow(contentRect: NSRect(x: screen.maxX - 820, y: screen.minY + 20, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.hasVerticalScroller = true
        let text = NSTextView(usingTextLayoutManager: true)
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = scratchText()
        scroll.documentView = text
        window.contentView = scroll
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        let shown = (Date().timeIntervalSince1970 - processStart()) * 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("LAUNCH appkit · first window \(Int(shown.rounded())) ms after process start · idle footprint \(footprintMB()) MB")
            fflush(stdout)
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
