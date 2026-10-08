// Nib in the Dock. The ✕ badge (PRD AP8, A9, V11): while any open file has conflict blocks in
// its text, Blit's muted-red pixel ✕ on Nib's icon, gone as the last one is resolved or its file
// closes. Nib has no long jobs, so no progress cells and no ✓ (A9). Drawn as Blit draws its
// badge: copied from Blit at 2dfcd8d (Blit/Views/DockProgress.swift, `DockTileView`'s badge),
// 2026-10-06; Nib's own now (PRD §7). And the icon itself, which Settings › General can hide
// (AP6) while the nib in the menu bar is shown, so Nib can always be reached.

import AppKit
import NibSync

/// Nib's icon in the Dock (AP6): hidden, Nib is an accessory app, not in the Dock or ⌘Tab and with
/// no menu bar of its own, reached by the nib in the menu bar, Show Scratch and its windows.
@MainActor
enum DockIcon {
    /// Settings › General's "Show Nib in the Dock" off, and the nib in the menu bar on.
    static var hidden: Bool {
        NibDefaults.store.bool(forKey: "hideDockIcon") && MenuBarController.enabledInSettings
    }

    /// At launch, before a window shows, and whenever the settings change.
    static func apply() {
        let policy: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }
}

@MainActor
final class DockBadge {
    static let shared = DockBadge()
    private let view = DockBadgeView()
    /// The ✕ is on the icon.
    private(set) var showing = false

    /// Looked at again whenever a file's conflict blocks change, and as a file closes.
    func update() {
        let conflicts = Documents.all.contains { !$0.blocks.isEmpty }
        guard conflicts != showing else { return }
        showing = conflicts
        let tile = NSApp.dockTile
        if conflicts {
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    #if DEBUG
    /// The icon with its ✕, as a PNG, for the `dock` scenario's picture.
    func picture(size: CGFloat = 256) -> Data? {
        let view = DockBadgeView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
    #endif
}

private final class DockBadgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let unit = bounds.width / 128   // designed on a 128-point grid
        let box = NSRect(x: bounds.width - 46 * unit, y: 6 * unit, width: 40 * unit, height: 40 * unit)
        NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1).setFill()   // the one red (V3)
        NSBezierPath(roundedRect: box, xRadius: 6 * unit, yRadius: 6 * unit).fill()
        let px = (4 * unit).rounded(.down)
        NSColor(red: 0x1C / 255, green: 0x0E / 255, blue: 0x0E / 255, alpha: 1).setFill()
        for (y, row) in PixelGlyph.cross.rows.enumerated() {
            for (x, cell) in row.enumerated() where cell == "#" {
                NSRect(x: box.minX + 6 * unit + CGFloat(x) * px, y: box.maxY - 6 * unit - CGFloat(y + 1) * px, width: px, height: px).fill()
            }
        }
    }
}
