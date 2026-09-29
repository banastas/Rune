// Copied from Blit at 6d417b0 (Blit/Views/PixelArt.swift: `draw`, `image`; Blit/Views/
// MenuBarIcon.swift: the fixed-width template image and `failureMark`) for M2. Nib's own art
// is in nib/Views/MenuBar.swift. Replaced by the shared package (FamilyKit › PixelUI, PRD §7).

import AppKit

enum PixelArt {
    @MainActor private static var cache: [String: NSImage] = [:]

    /// Rows of "#" (solid) and "+" (30%) cells as a template image, cached.
    @MainActor
    static func image(_ rows: [String], cell: CGFloat) -> NSImage {
        let key = rows.joined(separator: "/") + "@\(cell)"
        if let cached = cache[key] { return cached }
        let width = CGFloat(rows.map(\.count).max() ?? 0) * cell
        let height = CGFloat(rows.count) * cell
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            draw(rows, cell: cell, at: .zero)
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    static func draw(_ rows: [String], cell: CGFloat, at origin: NSPoint) {
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" || ch == "+" {
                NSColor.black.withAlphaComponent(ch == "#" ? 1 : 0.3).setFill()
                NSRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell, width: cell, height: cell).fill()
            }
        }
    }
}

@MainActor
enum MenuBarMark {
    static let cell: CGFloat = 1.5

    /// Pixel rows as a menu bar template image of a fixed size, centered in the bar's 18 pt,
    /// so the item never nudges its neighbours (V10).
    static func image(_ rows: [String], width: CGFloat) -> NSImage {
        let height: CGFloat = 18
        let artHeight = CGFloat(rows.count) * cell
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            PixelArt.draw(rows, cell: cell, at: NSPoint(x: 0, y: ((height - artHeight) / 2).rounded()))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A small ✕ in the failure red, beside the icon while something needs a look. Not a
    /// template: it keeps its colour on light and dark menu bars.
    static let failure: NSImage = {
        let rows = ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        let image = NSImage(size: NSSize(width: 5 * cell, height: 18), flipped: true) { _ in
            NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1).setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: 5 + CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }()
}
