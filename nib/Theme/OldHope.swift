// An Old Hope · nib's globals (PRD HL10, themes/an-old-hope-nib.tmTheme), drawn by
// the M1 editor before highlighting exists. Colors are sRGB, as the scheme declares.

import AppKit

enum OldHope {
    static let background = color(0x1C1D21)
    static let foreground = color(0xF8F8F2)
    static let caret = color(0xF8F8F0)
    static let selection = color(0x49483E)
    static let inactiveSelection = color(0x3A3A3A)
    static let lineHighlight = color(0x272B34)
    /// Conflict blocks (§5.4): a dark tint of the one red behind the block, and its marker
    /// lines in the red's text tint (V3, #C98080), so they read as nib's, not the text's.
    static let conflictBlock = color(0x2B2124)
    static let conflictMarker = color(0xC98080)
    static let conflictBar = color(0xB35C5C)
    /// The scheme's own diff backgrounds (`markup.inserted`, `.deleted`, `.changed`), for the merge view (§5.5).
    static let markupInserted = color(0x253B22)
    static let markupDeleted = color(0x420E09)
    static let markupChanged = color(0x4A4A0F)
    static let comment = color(0x848484)

    /// SF Mono 13 until M2 imports the Sublime font (HL3).
    static var font: NSFont { .monospacedSystemFont(ofSize: 13, weight: .regular) }

    static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
