// Copied from Blit at ea8b893 (Blit/Views/TransferHUD.swift:383-451: `HUDPanel`, `HUDRow`,
// `CRTEffect` and `AnyTransition.crt`) for the sync HUD (PRD §5.3), 2026-10-06. Nib's own now
// (no shared package, PRD §7). Adapted: a row's value goes through `hudText`, for the pixel
// glyphs (✓ ▼ ▲) VT323 doesn't have, and its key is cut short rather than the value; and the
// CRT gives way to a fade under Reduce Motion (A16; Blit's app doesn't check it).

import SwiftUI

/// A boxed panel with its title in Silkscreen (V10, V12).
struct HUDPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(HUDFont.label()).foregroundStyle(HUDColor.dim).padding(.bottom, 2)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(Rectangle().strokeBorder(Color(white: 0.23), lineWidth: 1))
    }
}

/// Key on the left (dim), value on the right.
struct HUDRow: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(HUDColor.dim).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            hudText(value, glyphSize: 11).lineLimit(1).fixedSize()
        }
        .font(HUDFont.terminal(18))
    }
}

/// The HUD switching on and off like an old CRT: a bright line sweeps out
/// horizontally, then opens vertically; switching off runs it backwards.
struct CRTEffect: ViewModifier, Animatable {
    /// 0 = off, 1 = fully on.
    var progress: Double

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, progress))
        let line = 0.3   // share of the animation spent as a line
        let x = p < line ? max(0.02, p / line) : 1
        let y = p < line ? 0.015 : 0.015 + (p - line) / (1 - line) * 0.985
        content
            .brightness(p < 1 ? 0.6 * (1 - p) : 0)
            .scaleEffect(x: x, y: y, anchor: .center)
            .opacity(p < 0.01 ? 0 : 1)
    }
}

extension AnyTransition {
    static var crt: AnyTransition {
        .modifier(active: CRTEffect(progress: 0), identity: CRTEffect(progress: 1))
    }

    /// The CRT, or a fade under Reduce Motion (A16).
    static func crt(reduceMotion: Bool) -> AnyTransition { reduceMotion ? .opacity : .crt }
}

extension Animation {
    /// Blit's HUD timing: a strong ease-out, 0.36 s.
    static var crt: Animation { .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36) }
}
