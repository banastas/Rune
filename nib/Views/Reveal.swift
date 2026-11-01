// Scrolling to a place in the text by geometry (TextKit 2): the line there laid out first, then
// the view scrolled to its rectangle. Never through `scrollRangeToVisible` or the find indicator:
// AppKit keeps the range of a scroll it can't finish yet (a place far from what's laid out) to
// finish after a later layout, and Nib's own changes in between rebuild the text it points into
// (the bold and italic `Editor.applyFaces` sets on the text storage as colors come in for the
// stretch just scrolled to; an edit). That later layout then crashed in AppKit's
// `__NSTextViewScrollContainerViewToTextRange`: after a scroll to a stretch, then typing
// (`widescroll`, 2026-10-02), and twice with Find in the user's 223 KB scratch file (2026-10-04).

import AppKit

extension NSTextView {
    /// The rectangle of the line `location` is on, in this view's coordinates: one point wide, at
    /// the place itself. The line is laid out first (TextKit 2 does that without laying out the
    /// text before it). Nil without TextKit 2.
    func placeRect(at location: Int) -> NSRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let at = min(max(0, location), textStorage?.length ?? 0)
        guard let place = content.location(content.documentRange.location, offsetBy: at) else { return nil }
        layout.ensureLayout(for: content.location(place, offsetBy: 1).flatMap { NSTextRange(location: place, end: $0) } ?? NSTextRange(location: place))
        // Past the last character there's no fragment of its own: the last line's.
        var fragment = layout.textLayoutFragment(for: place)
        if fragment == nil, at > 0, let before = content.location(place, offsetBy: -1) { fragment = layout.textLayoutFragment(for: before) }
        guard let fragment else { return nil }
        let within = content.offset(from: fragment.rangeInElement.location, to: place)
        let line = fragment.textLineFragments.first { NSMaxRange($0.characterRange) > within } ?? fragment.textLineFragments.last
        let frame = fragment.layoutFragmentFrame
        let bounds = line?.typographicBounds ?? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let x = line.map { $0.locationForCharacter(at: min(max(within, $0.characterRange.location), NSMaxRange($0.characterRange))).x } ?? 0
        return NSRect(x: frame.minX + x + textContainerOrigin.x, y: frame.minY + bounds.minY + textContainerOrigin.y,
                      width: 1, height: max(bounds.height, 1))
    }

    /// A place in the text into view, scrolling as little as it takes, a line's room round it.
    /// Far from what's laid out, TextKit 2 places the line by its estimate of the text before it,
    /// and laying out what's then in view moves it (to 82% of 223 KB, a line or two out of view:
    /// `findjump`): so what's in view is laid out, and the place looked at again, up to three times.
    func reveal(_ location: Int) {
        for _ in 0..<3 {
            guard let rect = placeRect(at: location) else { return }
            let wanted = rect.insetBy(dx: -8, dy: -rect.height)
            if visibleRect.contains(wanted) { return }
            scrollToVisible(wanted)
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// Where the view is in the text: the first character of the paragraph at its top, and how
    /// far below that paragraph's first line the view's top is (`scroll(to:)` puts it back).
    func scrollAnchor() -> (location: Int, offset: CGFloat)? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        layout.textViewportLayoutController.layoutViewport()
        let top = visibleRect.minY
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top - textContainerOrigin.y))) else { return nil }
        let location = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard let rect = placeRect(at: location) else { return nil }
        return (location, top - rect.minY)
    }

    /// The view where `scrollAnchor` said, its location moved by an edit since. The viewport is
    /// laid out first: just after an edit above the view, TextKit 2 still has the lines below it
    /// where they were (2,670 characters off, 30 lines into 254 KB, in a probe; 2026-11-01).
    func scroll(to anchor: (location: Int, offset: CGFloat)) {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        for _ in 0..<3 {
            guard let rect = placeRect(at: anchor.location) else { return }
            let top = max(0, rect.minY + anchor.offset)
            if abs(visibleRect.minY - top) < 1 { return }
            scroll(NSPoint(x: visibleRect.minX, y: top))
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }

    /// The line `location` is on at the top of the view, `linesAbove` lines down from it; laid
    /// out and looked at again as `reveal(_:)` does.
    func reveal(_ location: Int, linesAbove: Int) {
        for _ in 0..<3 {
            guard let rect = placeRect(at: location) else { return }
            let top = max(0, rect.minY - CGFloat(linesAbove) * rect.height)
            if abs(visibleRect.minY - top) < 1 { return }
            scroll(NSPoint(x: visibleRect.minX, y: top))
            textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }
}
