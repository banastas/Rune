// A confirmation with no window of Nib's in front (PRD PT4, SC6): one HUD line at the top
// of the screen for a few seconds, never taking focus. The menu bar panel's place until the
// menu bar extra exists (§5.7). VoiceOver hears it too.

import AppKit
import SwiftUI

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hide: DispatchWorkItem?
    /// The last line shown, and its panel, for the test harness.
    private(set) static var last: String?
    static var window: NSPanel? { panel }

    static func show(_ text: String, for seconds: Double = 2.5) {
        last = text
        let view = NSHostingView(rootView: ToastView(text: text))
        view.frame.size = view.fittingSize
        let panel = self.panel ?? {
            let made = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            made.level = .statusBar
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = true
            made.ignoresMouseEvents = true
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            return made
        }()
        self.panel = panel
        panel.contentView = view
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - view.fittingSize.width / 2, y: frame.maxY - view.fittingSize.height - 12,
                                  width: view.fittingSize.width, height: view.fittingSize.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text.lowercased(), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hide?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        hudText(text, glyphSize: 11)
            .font(HUDFont.terminal(16))
            .foregroundStyle(HUDColor.bright)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HUDColor.border, lineWidth: 0.5))
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }
}
