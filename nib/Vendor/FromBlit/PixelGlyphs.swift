// Copied from Blit at ac3f1ce (Blit/Views/PixelGlyphs.swift) for the weekend MVP.
// Nib's own now (no shared package, PRD §7).
//
// Pixel glyphs for the HUD. Silkscreen and VT323 have no ✓ ✕ ▲ ▼ →, so the
// system would draw smooth fallback glyphs; these 7×7 bitmaps keep the HUD
// on its 1-bit grid. Rendered as template images inline with Text.

import AppKit
import SwiftUI

enum PixelGlyph: Character, CaseIterable {
    case check = "✓", cross = "✕", up = "▲", down = "▼", arrow = "→", pause = "‖", play = "▶", partial = "◐"

    var rows: [String] {
        switch self {
        case .check: [".......", "......#", ".....#.", "#...#..", ".#.#...", "..#....", "......."]
        case .cross: ["#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#"]
        case .up:    [".......", "...#...", "..###..", ".#####.", "#######", ".......", "......."]
        case .down:  [".......", ".......", "#######", ".#####.", "..###..", "...#...", "......."]
        case .arrow: [".......", "....#..", ".....#.", "#######", ".....#.", "....#..", "......."]
        case .pause: [".......", ".##.##.", ".##.##.", ".##.##.", ".##.##.", ".##.##.", "......."]
        case .play:  [".#.....", ".##....", ".###...", ".####..", ".###...", ".##....", ".#....."]
        case .partial: ["#######", "####..#", "####..#", "####..#", "####..#", "####..#", "#######"]
        }
    }

    /// What VoiceOver says for the glyph standing alone, in Nib's meanings, not Blit's transfer
    /// words ("done", "transferring", "down": the QA review's F39). Inside HUD text it says nothing:
    /// a word always follows it there ("✓ SYNCED", "▲ UPLOADED"), and "done SYNCED" was what it heard.
    var spoken: String {
        switch self {
        case .check: "synced"
        case .cross: "problem"
        case .up: "uploading"
        case .down: "came in"
        case .arrow: "to"
        case .pause: "waiting"
        case .play: "resume"
        case .partial: "not here"
        }
    }

    /// A template image `size` points tall (whole pixels per cell, so edges stay crisp).
    @MainActor
    func image(size: CGFloat) -> NSImage {
        let key = "\(rawValue)@\(size)"
        if let cached = Self.cache[key] { return cached }
        let cell = max(1, (size / 7).rounded(.down))
        let side = cell * 7
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = spoken
        Self.cache[key] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]
}

/// HUD text with ✓ ✕ ▲ ▼ → drawn as pixel glyphs; everything else as text.
@MainActor
func hudText(_ string: String, glyphSize: CGFloat = 11) -> Text {
    var result = Text(verbatim: "")
    var run = ""
    for ch in string {
        if let glyph = PixelGlyph(rawValue: ch) {
            if !run.isEmpty { result = Text("\(result)\(Text(verbatim: run))"); run = "" }
            result = Text("\(result)\(Text(Image(nsImage: glyph.image(size: glyphSize))).baselineOffset(-1).accessibilityLabel(""))")   // the word after it says it (F39)
        } else {
            run.append(ch)
        }
    }
    if !run.isEmpty { result = Text("\(result)\(Text(verbatim: run))") }
    return result
}
