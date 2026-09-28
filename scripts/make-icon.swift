// Renders Nib's app icon as an Icon Composer document (nib/AppIcon.icon), by Blit's recipe
// (PRD §5.11, V11): a solid near-black fill plus one full-bleed pixel-art layer, glass off,
// on Blit's 14×12 grid. The art is a fountain-pen nib, diagonal, with its breather hole and
// slit, writing on the same bottom row as Blit's icon, the family mark. macOS applies the
// icon shape itself. The same script as Blit's scripts/make-icon.swift but for the art and
// the name, until the shared package (§7) holds one copy.
//
//   swift scripts/make-icon.swift nib/AppIcon.icon [preview.png]
import AppKit

let name = "nib"
let art = [
    "........####..",
    ".......#####..",
    "......######..",
    ".....######...",
    "....##..##....",   // the breather hole
    "...###.##.....",   // the slit, down to the tip
    "..###.##......",
    "..##.##.......",
    ".##.#.........",
    ".#............",   // the tip, writing on
    "..............",
    "##.##.##.##.::",   // the family mark: Blit's progress cells, last one dim
]
let bundle = CommandLine.arguments[1]
let canvas = 1024

/// The pixel layer; with `background`, the whole icon as a squircle-ish preview.
func render(background: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    if background {
        ctx.setShouldAntialias(true)
        let inset = CGFloat(canvas) * 0.1, size = CGFloat(canvas) - 2 * inset
        ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: size, height: size),
                           cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil))
        ctx.setFillColor(CGColor(gray: 0.045, alpha: 1))
        ctx.fillPath()
    }
    ctx.setShouldAntialias(false)
    let cols = art[0].count, rows = art.count
    let cell = Int(Double(canvas) * 0.56) / cols           // whole pixels per cell
    let x0 = (canvas - cell * cols) / 2
    let y0 = (canvas - cell * rows) / 2
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() where ch != "." {
            ctx.setFillColor(CGColor(gray: ch == ":" ? 0.3 : 0.95, alpha: 1))
            ctx.fill(CGRect(x: x0 + c * cell, y: y0 + (rows - 1 - r) * cell, width: cell, height: cell))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(atPath: bundle)
try! fm.createDirectory(atPath: bundle + "/Assets", withIntermediateDirectories: true)
try! render(background: false).write(to: URL(fileURLWithPath: bundle + "/Assets/\(name).png"))
let json = """
{
  "fill" : {
    "solid" : "extended-srgb:0.04500,0.04500,0.04500,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "\(name).png",
          "name" : "\(name)"
        }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
"""
try! json.write(toFile: bundle + "/icon.json", atomically: true, encoding: .utf8)
print("wrote \(bundle)")
if CommandLine.arguments.count > 2 {
    try! render(background: true).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("wrote \(CommandLine.arguments[2])")
}
