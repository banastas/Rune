// The find bar (PRD ED7, KB1): under the text, over the strip, dark like the strip (A17).
// Find, and with ⌥⌘F Replace; the options as Sublime shows them (.* regular expression,
// Aa match case, whole word, in the selection); the count in the HUD's words, and a pattern
// that isn't a regular expression said plainly (W2). Return goes to the next match, ⇧Return
// the one before, ⌥Return selects them all (Find All, a caret each), Escape closes it.

import AppKit
import NibText
import SwiftUI

struct FindBar: View {
    @Bindable var find: FindSession

    var body: some View {
        VStack(spacing: 6) {
            // In one row they need about 700 points, more than a window's 480 (the QA review's F58):
            // narrower, the options and buttons take a row of their own. Laid out, not chosen by a
            // measured width: changing the views as the bar appeared took the focus from the field
            // just as ⌘F gave it (`findjump`'s keys went into the text).
            FindBarLayout {
                Button { find.replacing.toggle() } label: {
                    Image(systemName: find.replacing ? "chevron.down" : "chevron.right").frame(width: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(HUDColor.dim)
                .help(find.replacing ? "Hide Replace" : "Show Replace (⌥⌘F)")
                .accessibilityLabel(find.replacing ? "Hide Replace" : "Show Replace")
                FindField(text: $find.query, placeholder: "Find", label: "Find", focusRequests: find.focusRequests,
                          onReturn: { shift in find.next(backwards: shift) }, onEscape: { find.close() })
                Text(find.countLabel)
                    .font(HUDFont.terminal(16))
                    .foregroundStyle(find.failure != nil || (find.matches.isEmpty && !find.query.isEmpty) ? HUDColor.failureText : HUDColor.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 90, maxWidth: find.failure == nil ? 150 : 320, alignment: .leading)
                    .help(find.failure.map { _ in "The pattern isn't a regular expression Nib can read. Check the brackets and escapes, or turn off .* to find it as typed." } ?? "Matches in the text")
                    .accessibilityLabel(find.countLabel.isEmpty ? "No search" : Spoken.sentence(find.countLabel))   // F61
                controls
            }
            if find.replacing {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 12, height: 1)
                    FindField(text: $find.replacement, placeholder: find.options.regex ? "Replace ($1 for the first group)" : "Replace",
                              label: "Replace", focusRequests: 0,
                              onReturn: { _ in find.replaceCurrent() }, onEscape: { find.close() })
                    Button("Replace") { find.replaceCurrent() }
                        .help("Replace this match and go to the next (⌥⌘E)")
                    Button("Replace All") { find.replaceAll() }
                        .help(find.inSelection ? "Replace every match in the selection, as one undo (⌃⌥Return)" : "Replace every match, as one undo (⌃⌥Return)")
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(HUDColor.background)
        .overlay(alignment: .top) { Rectangle().fill(HUDColor.border).frame(height: 0.5) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find")
    }

    /// The options and the buttons: in the find row, or a row of their own (`FindBarLayout`).
    private var controls: some View {
        HStack(spacing: 8) {
            optionToggle(".*", isOn: $find.options.regex, help: "Regular expression: $1 in Replace is the first group")
            optionToggle("Aa", isOn: $find.options.matchCase, help: "Match case")
            optionToggle("ab", underline: true, isOn: $find.options.wholeWord, help: "Whole words only")
            optionToggle("In Selection", isOn: $find.inSelection, help: "Only in what was selected when this was turned on")
            Button { find.next(backwards: true) } label: { Image(systemName: "chevron.left") }
                .help("Previous match (⇧⌘G)")
                .accessibilityLabel("Previous match")
            Button { find.next() } label: { Image(systemName: "chevron.right") }
                .help("Next match (⌘G)")
                .accessibilityLabel("Next match")
            Button("Find All") { find.findAll() }
                .help("Select every match, a caret at each (⌥Return)")
            Button("Done") { find.close() }
                .help("Close the find bar (Escape)")
        }
        .fixedSize()
    }

    private func optionToggle(_ title: String, underline: Bool = false, isOn: Binding<Bool>, help: String) -> some View {
        Toggle(isOn: isOn) { Text(title).underline(underline).monospaced(title.count <= 2) }
            .toggleStyle(.button)
            .help(help)
            .accessibilityLabel(help.components(separatedBy: ":").first ?? help)
    }
}

/// The find row: the chevron, the field, the count and the controls in one row when the field
/// keeps at least `fieldMinimum` points; else the controls in a second row, at its right. The
/// field takes what the others leave.
struct FindBarLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 6
    var fieldMinimum: CGFloat = 200

    private func measure(_ subviews: Subviews, width: CGFloat) -> (chevron: CGSize, field: CGSize, count: CGSize, controls: CGSize, oneRow: Bool) {
        let chevron = subviews[0].sizeThatFits(.unspecified), count = subviews[2].sizeThatFits(.unspecified)
        let controls = subviews[3].sizeThatFits(.unspecified), field = subviews[1].sizeThatFits(.unspecified)
        let oneRow = chevron.width + fieldMinimum + count.width + controls.width + spacing * 3 <= width
        return (chevron, field, count, controls, oneRow)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let width = proposal.width ?? 900
        let m = measure(subviews, width: width)
        let first = max(m.chevron.height, m.field.height, m.count.height, m.oneRow ? m.controls.height : 0)
        return CGSize(width: width, height: m.oneRow ? first : first + rowSpacing + m.controls.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let m = measure(subviews, width: bounds.width)
        let first = max(m.chevron.height, m.field.height, m.count.height, m.oneRow ? m.controls.height : 0)
        let mid = bounds.minY + first / 2
        var x = bounds.minX
        subviews[0].place(at: CGPoint(x: x, y: mid), anchor: .leading, proposal: ProposedViewSize(m.chevron))
        x += m.chevron.width + spacing
        let right = bounds.maxX - m.count.width - (m.oneRow ? m.controls.width + spacing * 2 : spacing)
        subviews[1].place(at: CGPoint(x: x, y: mid), anchor: .leading, proposal: ProposedViewSize(width: max(0, right - x), height: m.field.height))
        subviews[2].place(at: CGPoint(x: right + spacing, y: mid), anchor: .leading, proposal: ProposedViewSize(m.count))
        if m.oneRow {
            subviews[3].place(at: CGPoint(x: bounds.maxX, y: mid), anchor: .trailing, proposal: ProposedViewSize(m.controls))
        } else {
            subviews[3].place(at: CGPoint(x: bounds.maxX, y: bounds.minY + first + rowSpacing), anchor: .topTrailing, proposal: ProposedViewSize(m.controls))
        }
    }
}

/// A plain AppKit text field, for the keys SwiftUI's doesn't pass on: Return and ⇧Return,
/// and Escape. `focusRequests` changing puts the caret in it with its text selected.
struct FindField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let label: String
    let focusRequests: Int
    let onReturn: (_ shift: Bool) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = Field()
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // Not while it's being typed in: that would move the caret to the end.
        if field.stringValue != text, field.currentEditor() == nil || context.coordinator.focused != focusRequests {
            field.stringValue = text
        }
        if focusRequests > 0, context.coordinator.focused != focusRequests {
            context.coordinator.focused = focusRequests
            DispatchQueue.main.async { (field as? Field)?.takeFocus() }
        }
    }

    /// Takes the caret when asked, or as soon as it's in a window: a bar just opened may not be
    /// in one yet when the request comes (⌘F then left the caret in the text, now and then).
    final class Field: NSTextField {
        private var wantsFocus = false

        func takeFocus() {
            guard let window else { wantsFocus = true; return }
            wantsFocus = false
            window.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsFocus, window != nil { DispatchQueue.main.async { self.takeFocus() } }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindField
        var focused = 0

        init(_ parent: FindField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onReturn(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}
