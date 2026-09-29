// Copied from Blit at 6d417b0 (Blit/Views/CommandPalette.swift) for M2, and generalized: an
// entry carries its own group label and, for a command, its keys; what choosing one does is
// the caller's. Replaced by the shared package's palette (PRD §7, A6). Keep the scoring and
// the keys in step with Blit until then.

import SwiftUI

struct PaletteEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    /// On the right of the row ("Recent"); empty for none.
    let group: String
    /// A command's keys ("⇧⌘D"), on the right.
    var shortcut: String? = nil
}

struct CommandPalette: View {
    let entries: [PaletteEntry]
    var prompt = "Go to a file"
    /// Entries made from the query itself, above the rest (":12" is a line to go to).
    var extra: (String) -> [PaletteEntry] = { _ in [] }
    let onSelect: (PaletteEntry) -> Void
    @State private var query = ""
    @State private var highlighted: PaletteEntry.ID?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [PaletteEntry] { Self.results(for: query, in: entries, extra: extra) }

    /// The entries that match, best first: a name match above a detail match, and within a
    /// score the list's own order.
    static func results(for query: String, in entries: [PaletteEntry], extra: (String) -> [PaletteEntry] = { _ in [] }) -> [PaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return extra(q) + entries.enumerated()
            .compactMap { index, entry -> (PaletteEntry, Int, Int)? in
                if let s = Self.score(q, entry.name.lowercased()) { return (entry, s + 10, index) }
                if let s = Self.score(q, entry.detail.lowercased()) { return (entry, s, index) }
                return nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }   // ties keep the list's order (Scratch, Open, Recent…)
            .map(\.0)
    }

    /// Prefix beats substring beats in-order letters (so "mmov" finds Media › Movies).
    static func score(_ query: String, _ text: String) -> Int? {
        if text.hasPrefix(query) { return 3 }
        if text.contains(query) { return 2 }
        var remaining = query[...]
        for c in text where c == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 1 }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .accessibilityLabel(prompt)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(results, selection: $highlighted) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let shortcut = entry.shortcut {
                            Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        if !entry.group.isEmpty {
                            Text(entry.group).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tag(entry.id)
                    .id(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { select(entry) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel([entry.name, entry.detail, entry.shortcut, entry.group.isEmpty ? nil : entry.group].compactMap { $0 }.joined(separator: ", "))
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(height: 300)
            .overlay {
                if results.isEmpty { Text("No matches").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 520)
        .onAppear {
            fieldFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { highlighted = results.first?.id }
        .onChange(of: entries) { if highlighted == nil || !results.contains(where: { $0.id == highlighted }) { highlighted = results.first?.id } }
    }

    private func move(_ delta: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? -1
        highlighted = list[max(0, min(list.count - 1, index + delta))].id
    }

    private func openHighlighted() {
        if let entry = results.first(where: { $0.id == highlighted }) ?? results.first { select(entry) }
    }

    private func select(_ entry: PaletteEntry) {
        onSelect(entry)
        dismiss()
    }
}
