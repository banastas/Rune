// Nib › About Nib (PRD §5.10, V5, V7, V12): Blit's About, in Nib's words. Copied from Blit at
// de24207 (Blit/Views/AboutView.swift), 2026-10-06; Nib's own now (PRD §7). The pixel icon at
// 96 pt, NIB in Silkscreen 34, the tagline with a blinking `_` (lit and still under Reduce
// Motion, A16), a dashed divider, the version, and the third-party notices (DS3).

import SwiftUI

struct AboutView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "V\(short) · BUILD \(build)"
    }

    /// "Version 0.1, build 3", for VoiceOver (it read "V0.1 · BUILD 3": F82).
    static var spokenVersion: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "?"), build \(info?["CFBundleVersion"] as? String ?? "?")"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.none)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("NIB").font(HUDFont.label(34))
                .accessibilityLabel("Nib")   // not spelled out (F82)
            HStack(spacing: 0) {
                Text("WRITE IT DOWN. LOSE NOTHING")
                if reduceMotion {
                    Text("_")
                } else {
                    TimelineView(.periodic(from: .now, by: 0.55)) { context in
                        Text("_").opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0)
                    }
                }
            }
            .font(HUDFont.terminal(17))
            .foregroundStyle(HUDColor.dim)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Write it down. Lose nothing.")
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(HUDColor.off))
                .padding(.vertical, 4)
            Text(Self.version).font(HUDFont.terminal(20))
                .accessibilityLabel(Self.spokenVersion)
            // The open-source software Nib ships, with its notices and licenses (the fonts' among
            // them, and An Old Hope's), as each asks (DS3).
            Button { openWindow(id: "acknowledgements") } label: {
                Text("ACKNOWLEDGEMENTS ›")
                    .font(HUDFont.terminal(16))
                    .foregroundStyle(hovering ? HUDColor.bright : HUDColor.dim)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("The open-source software in Nib, with its copyright notices and licenses")
        }
        .foregroundStyle(HUDColor.bright)
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: 360)
        .background(HUDColor.background)
        .environment(\.colorScheme, .dark)
        #if DEBUG
        .onAppear { if TestHarness.openAcknowledgements { openWindow(id: "acknowledgements") } }   // the `about` scenario
        #endif
    }
}
