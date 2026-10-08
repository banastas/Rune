// nib-textspike (M0 S2): TextKit 1 vs TextKit 2 in an NSTextView at scratch sizes.
// Generated text only. The window sits on screen at 1% opacity, never becomes key
// and ignores the mouse, so it draws at Retina scale without taking focus.
//
//   nib-textspike --engine tk1|tk2 --size 2.4m --keys 300 --highlight none|window --full-layout yes|no
//
// Keystrokes are inserted with insertText, then the window is displayed
// synchronously: the time is nib's own share of keystroke latency (layout and
// drawing on the CPU), not the full trip to the glass.

import AppKit
import QuartzCore

// MARK: - Options and helpers

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return fallback }
    return arguments[i + 1]
}
func bytes(_ text: String) -> Int {
    let lower = text.lowercased()
    let unit: Double = lower.hasSuffix("m") ? 1_048_576 : lower.hasSuffix("k") ? 1024 : 1
    return Int((Double(lower.trimmingCharacters(in: CharacterSet(charactersIn: "km"))) ?? 0) * unit)
}

let engine = option("engine", "tk2")
let size = bytes(option("size", "2.4m"))
let keyCount = Int(option("keys", "300")) ?? 300
let highlightMode = option("highlight", "window")

func now() -> CFTimeInterval { CACurrentMediaTime() }
func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 10_000).rounded() / 10 }

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? (Double(info.phys_footprint) / 1_048_576 * 10).rounded() / 10 : -1
}

func summary(_ samples: [Double]) -> String {
    let s = samples.sorted()
    guard !s.isEmpty else { return "—" }
    func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
    return "p50 \(p(0.5)) · p95 \(p(0.95)) · p99 \(p(0.99)) · max \(s.last!) ms"
}

/// Scratch-shaped Markdown: short lines, code fences, headings, and every 25th
/// line a long paragraph (an email draft) that soft-wraps.
func generatedText(bytes target: Int) -> String {
    let words = ["deploy", "ssh", "draft", "vendor", "invoice", "rsync", "build", "notes", "call", "review",
                 "ship", "tuesday", "queue", "server", "hash", "reply", "thanks", "follow", "up", "check"]
    var state = 7
    func next() -> Int { state = (state &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff; return state }
    func sentence(_ n: Int) -> String { (0..<n).map { _ in words[next() % words.count] }.joined(separator: " ") }
    var text = "# nib text spike\n\n"
    var line = 0
    while text.utf8.count < target {
        line += 1
        switch line % 40 {
        case 0: text += "\n## Section \(line / 40)\n\n"
        case 7: text += "```bash\nrsync -av ~/src/ host:/srv/\(next() % 999)/ && ssh host 'df -h'\n```\n"
        case 13: text += "- **\(sentence(2))** `\(sentence(1))` and [link](https://example.com/\(next() % 99))\n"
        case 25: text += (0..<12).map { _ in sentence(12).capitalized + "." }.joined(separator: " ") + "\n"
        default: text += sentence(4 + next() % 9) + "\n"
        }
    }
    return text
}

// MARK: - Stand-in highlighter
// Regular expressions for Markdown, applied as rendering-only attributes in a
// window of text around the edit (about what a viewport highlighter touches).
// S3 replaces this with tree-sitter; here it only supplies realistic attribute churn.

let palette: [(NSRegularExpression, NSColor)] = [
    (#"^#{1,6} .*$"#, "E7CE57"), (#"^```.*$"#, "848484"), (#"`[^`\n]+`"#, "78BC65"),
    (#"\*\*[^*\n]+\*\*"#, "EF7C2B"), (#"^\s*[-*] "#, "EF7C2B"), (#"\[[^\]\n]+\]\([^)\n]+\)"#, "50B4D8"),
    (#"\b(rsync|ssh|deploy|build)\b"#, "EC475D"), (#"\b\d+\b"#, "EF7C2B"),
].map { pattern, hex in
    let v = Int(hex, radix: 16)!
    return (try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
            NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1))
}
let foreground = NSColor(srgbRed: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF2 / 255, alpha: 1)
let background = NSColor(srgbRed: 0x1C / 255, green: 0x1D / 255, blue: 0x21 / 255, alpha: 1)

func tokens(in string: NSString, range: NSRange) -> [(NSRange, NSColor)] {
    var out: [(NSRange, NSColor)] = []
    for (regex, color) in palette {
        regex.enumerateMatches(in: string as String, options: [], range: range) { match, _, _ in
            if let r = match?.range { out.append((r, color)) }
        }
    }
    return out
}

// MARK: - The text view, either engine

final class Harness {
    let window: NSWindow
    let scroll: NSScrollView
    let textView: NSTextView
    let tk2: Bool

    init(tk2: Bool) {
        self.tk2 = tk2
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - 820, y: screen.minY + 20, width: 800, height: 900)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        textView = NSTextView(usingTextLayoutManager: tk2)
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = foreground
        textView.backgroundColor = background
        textView.insertionPointColor = foreground
        textView.textContainerInset = NSSize(width: 12, height: 8)
        if !tk2 { textView.layoutManager?.allowsNonContiguousLayout = true }   // only ever touched in TK1 mode
        scroll.documentView = textView
        window.contentView = scroll
        window.orderFrontRegardless()
    }

    /// Still on the engine it started with? (TK2 falls back to TK1 if anything touches layoutManager.)
    var engineNow: String { textView.textLayoutManager != nil ? "tk2" : "tk1" }

    func display() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func setColors(_ runs: [(NSRange, NSColor)], clearing range: NSRange) {
        if tk2 {
            guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
                  let clear = textRange(range, tcm) else { return }
            tlm.removeRenderingAttribute(.foregroundColor, for: clear)
            for (r, color) in runs {
                if let tr = textRange(r, tcm) { tlm.setRenderingAttributes([.foregroundColor: color], for: tr) }
            }
        } else {
            guard let lm = textView.layoutManager else { return }
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for (r, color) in runs { lm.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: r) }
        }
    }

    func textRange(_ r: NSRange, _ tcm: NSTextContentManager) -> NSTextRange? {
        guard let start = tcm.location(tcm.documentRange.location, offsetBy: r.location),
              let end = tcm.location(start, offsetBy: r.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Re-highlights about ±3,000 characters around `location`.
    /// The text storage's own string: `textView.string` copies the whole document.
    var storage: NSString { textView.textStorage?.mutableString ?? (textView.string as NSString) }

    func highlightWindow(around location: Int) {
        let string = storage
        let start = max(0, location - 3000)
        let window = NSRange(location: start, length: min(string.length - start, 6000))
        let lineRange = string.lineRange(for: window)
        setColors(tokens(in: string, range: lineRange), clearing: lineRange)
    }
}

// MARK: - Run

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { self.run(); NSApp.terminate(nil) }
    }

    func run() {
        let baseline = footprintMB()
        let text = generatedText(bytes: size)
        let lines = text.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        let h = Harness(tk2: engine == "tk2")
        h.display()
        let emptyWindow = footprintMB()

        var t = now()
        h.textView.string = text
        h.textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        h.textView.textColor = foreground
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        h.display()
        let openMs = ms(now() - t)

        // Whole-document highlight, as a parser would hand over after opening.
        t = now()
        let all = tokens(in: h.storage, range: NSRange(location: 0, length: h.storage.length))
        let tokenMs = ms(now() - t)
        var fullMs = -1.0
        if highlightMode != "none" {
            t = now()
            h.setColors(all, clearing: NSRange(location: 0, length: h.storage.length))
            h.display()
            fullMs = ms(now() - t)
        }
        var layoutMs = -1.0
        if option("full-layout", "no") == "yes" {
            t = now()
            if h.tk2, let tlm = h.textView.textLayoutManager {
                tlm.ensureLayout(for: tlm.documentRange)
            } else if let lm = h.textView.layoutManager, let container = h.textView.textContainer {
                lm.ensureLayout(for: container)
            }
            h.display()
            layoutMs = ms(now() - t)
        }
        let afterOpen = footprintMB()

        // Keystrokes at the end, then in the middle.
        var report: [String] = []
        for (label, fraction) in [("end", 1.0), ("middle", 0.5)] {
            let length = h.storage.length
            let at = Int(Double(length) * fraction)
            h.textView.setSelectedRange(NSRange(location: at, length: 0))
            h.textView.scrollRangeToVisible(NSRange(location: at, length: 0))
            h.display()
            var samples: [Double] = []
            for n in 0..<keyCount {
                autoreleasepool {
                    let start = now()
                    let range = h.textView.selectedRange()
                    if n % 23 == 22 {
                        h.textView.deleteBackward(nil)
                    } else {
                        h.textView.insertText(n % 17 == 16 ? "\n" : "a", replacementRange: range)
                    }
                    if highlightMode == "window" { h.highlightWindow(around: h.textView.selectedRange().location) }
                    h.display()
                    samples.append(ms(now() - start))
                }
            }
            report.append("keys at \(label): \(summary(samples))")
        }
        let afterKeys = footprintMB()

        // Scrolling: jumps to random places, with the document height each time.
        var jumps: [Double] = []
        var heights: [CGFloat] = []
        var state = 3
        for _ in 0..<40 { autoreleasepool {
            state = (state &* 1_103_515_245 &+ 12_345) & 0x7fff_ffff
            let length = h.storage.length
            let target = state % max(1, length)
            let start = now()
            h.textView.scrollRangeToVisible(NSRange(location: target, length: 0))
            h.display()
            jumps.append(ms(now() - start))
            heights.append(h.textView.frame.height)
        } }
        let distinct = Set(heights.map { Int($0) }).count
        let spread = (heights.max() ?? 0) - (heights.min() ?? 0)

        print("RESULT \(engine) · \(option("size", "2.4m")) (\(size) bytes, \(lines) lines) · highlight \(highlightMode)")
        print("  open (set text + first display): \(openMs) ms")
        print("  tokenize whole document (regex stand-in): \(tokenMs) ms · \(all.count) tokens")
        print("  apply whole-document highlight + display: \(fullMs < 0 ? "—" : "\(fullMs) ms")")
        print("  lay out the whole document: \(layoutMs < 0 ? "not asked" : "\(layoutMs) ms")")
        report.forEach { print("  \($0)") }
        print("  scroll jumps: \(summary(jumps)) · document height took \(distinct) values, spread \(Int(spread)) pt")
        print("  memory (phys footprint): start \(baseline) MB · empty window \(emptyWindow) · after open \(afterOpen) · after typing \(afterKeys)")
        print("  engine at the end: \(h.engineNow)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
