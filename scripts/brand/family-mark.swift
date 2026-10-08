// The family mark as a logo (2026-10-08): the store's on Lemon Squeezy (banast.as, Blit and
// Rune's). The bottom row both app icons share, Blit's progress cells with the last one dim
// (scripts/make-icon.swift's art, "##.##.##.##.::"), alone, centred on near-black, in square
// cells with no smoothing.
//
//   swift scripts/brand/family-mark.swift <size> <out.png>
import AppKit

let row = "##.##.##.##.::"
let args = CommandLine.arguments
guard args.count == 3, let size = Int(args[1]) else {
    FileHandle.standardError.write(Data("usage: family-mark.swift <size> <out.png>\n".utf8))
    exit(2)
}
// The mark spans about 62% of the width, so a round crop keeps it whole; a whole number of
// pixels a cell, so every cell is the same.
let cell = Int((Double(size) * 0.62 / Double(row.count)).rounded(.down))
let width = cell * row.count
let x0 = (size - width) / 2, y0 = (size - cell) / 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = context
context.shouldAntialias = false
func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
color(0x0A0A0A).setFill()   // the HUD's black (HUDColor, the site's --bg)
NSRect(x: 0, y: 0, width: size, height: size).fill()
for (i, ch) in row.enumerated() where ch != "." {
    (ch == "#" ? color(0xF0F0F0) : color(0x4A4A4A)).setFill()   // bright, and the dim last cell
    NSRect(x: x0 + i * cell, y: y0, width: cell, height: cell).fill()
}
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("==> \(args[2]) (\(size)x\(size), cells of \(cell) px)")
