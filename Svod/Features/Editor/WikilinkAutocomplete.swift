import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - WikilinkAutocomplete
//
// Drives the `[[…` completion popover. The text view reports the active query
// (the text typed after an unclosed `[[`); this filters the vault note list with
// a light fuzzy match and exposes a selectable, keyboard-navigable list.

@MainActor
final class WikilinkAutocomplete: ObservableObject {
    @Published var isActive = false
    @Published var query = ""
    @Published var matches: [String] = []
    @Published var selection = 0
    /// Screen-space anchor (caret rect, window coords) the popover positions against.
    @Published var anchor: CGRect = .zero

    private var names: [String] = []

    func setNames(_ names: [String]) { self.names = names }

    func begin(query: String, anchor: CGRect) {
        self.query = query
        self.anchor = anchor
        recompute()
        isActive = !matches.isEmpty
    }

    func update(query: String, anchor: CGRect) {
        self.query = query
        self.anchor = anchor
        recompute()
        if matches.isEmpty { isActive = false }
        else { isActive = true; selection = min(selection, matches.count - 1) }
    }

    func dismiss() { isActive = false; query = ""; selection = 0 }

    func moveSelection(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }

    var selectedMatch: String? {
        guard matches.indices.contains(selection) else { return nil }
        return matches[selection]
    }

    private func recompute() {
        selection = 0
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { matches = Array(names.prefix(12)); return }
        matches = names
            .compactMap { name -> (String, Int)? in
                guard let score = Self.fuzzyScore(query: q, candidate: name.lowercased()) else { return nil }
                return (name, score)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Subsequence fuzzy match; lower score == tighter match. nil == no match.
    static func fuzzyScore(query: String, candidate: String) -> Int? {
        if candidate.hasPrefix(query) { return 0 }
        var qi = query.startIndex
        var gap = 0, lastHit = -1, idx = 0
        for ch in candidate {
            if qi < query.endIndex, ch == query[qi] {
                if lastHit >= 0 { gap += idx - lastHit - 1 }
                lastHit = idx
                qi = query.index(after: qi)
            }
            idx += 1
        }
        return qi == query.endIndex ? gap + 1 : nil
    }
}

// MARK: - Popover view
struct WikilinkPopover: View {
    @ObservedObject var model: WikilinkAutocomplete
    let resolves: (String) -> Bool
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.matches.enumerated()), id: \.element) { idx, name in
                row(name, selected: idx == model.selection)
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(name) }
            }
        }
        .padding(Spacing.xxs)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radii.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.md, style: .continuous)
            .strokeBorder(ThemeColor.borderSubtle))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Link suggestions")
    }

    private func row(_ name: String, selected: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: resolves(name) ? "doc.text" : "doc.badge.plus")
                .imageScale(.small)
                .foregroundStyle(resolves(name) ? ThemeColor.link : ThemeColor.linkUnresolved)
            Text(name)
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !resolves(name) {
                Text("new").font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(selected ? ThemeColor.surfaceSelected : .clear,
                    in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
