// Copied from Blit at ac3f1ce (Blit/Views/TransferStrip.swift:9-46 and
// Blit/Views/SidebarView.swift:347-356) for the weekend MVP. Nib's own now (no shared
// package, PRD §7): take Blit's later changes to the look when they suit.

import AppKit
import CoreText
import SwiftUI

enum HUDFont {
    /// Registers bundled fonts (Silkscreen, VT323; SIL OFL) once at launch.
    static func registerBundled() {
        for ext in ["ttf", "otf"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    /// Pixel uppercase labels; system monospaced small caps until the font is bundled.
    static func label(_ size: CGFloat = 11) -> Font {
        NSFont(name: "Silkscreen-Regular", size: size) != nil
            ? .custom("Silkscreen-Regular", fixedSize: size)
            : .system(size: size - 1, weight: .medium, design: .monospaced).smallCaps()
    }

    /// Terminal numerals and text.
    static func terminal(_ size: CGFloat) -> Font {
        NSFont(name: "VT323-Regular", size: size) != nil
            ? .custom("VT323-Regular", fixedSize: size)
            : .system(size: size * 0.72, design: .monospaced)
    }
}

enum HUDColor {
    static let background = Color(white: 0.04)
    static let border = Color(white: 0.17)
    static let bright = Color(white: 0.94)
    static let dim = Color(white: 0.49)
    static let off = Color(white: 0.15)
    /// Fills and tags (the WARNING tag and panel). Black text on it measures 4.6:1.
    static let failure = Color.failure
    static let onFailure = Color.black
    /// Failure text on the HUD's black: the lighter tint of the same red
    /// (#C98080, 6.5:1; #b35c5c itself is 4.3:1, under WCAG AA for small text).
    static let failureText = Color(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255)
}

extension Color {
    /// Muted red, used only for failures (PRD Visual language): fills, tags, glyphs.
    static let failure = Color(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255)
    /// The same red for failure text: #b35c5c in light mode (4.6:1 on white),
    /// its lighter tint #C98080 in dark mode, where #b35c5c falls under 4.5:1.
    static let failureText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
            : NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1)
    })
}
