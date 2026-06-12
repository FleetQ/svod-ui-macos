import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 1 — Editor & Frontmatter
// ════════════════════════════════════════════════════════════════════════

// MARK: - FrontmatterPanel
//
// A collapsible Card rendering the leading YAML block as typed property rows —
// scalars as inline fields, lists (tags, aliases) as editable chips. Edits flow
// back through `onChange(Frontmatter)`; EditorView recomposes the note text.

struct FrontmatterPanel: View {
    let frontmatter: Frontmatter
    var onChange: (Frontmatter) -> Void

    @State private var expanded = true
    @State private var newChipText: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().overlay(ThemeColor.separator)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(Array(frontmatter.entries.enumerated()), id: \.offset) { idx, entry in
                        if entry.modeled, !entry.key.isEmpty {
                            row(entry, index: idx)
                        }
                    }
                }
                .padding(Spacing.md)
            }
        }
        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
            .strokeBorder(ThemeColor.borderSubtle))
        .accessibilityElement(children: .contain)
    }

    // MARK: header (fold toggle)
    private var header: some View {
        Button {
            withAnimation(Motion.quick) { expanded.toggle() }
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                SectionLabel("Properties", systemImage: "tag")
                Spacer()
                if let title = scalar("title"), !expanded {
                    Text(title).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: Spacing.rowHeightComfortable)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Properties, \(expanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: rows
    @ViewBuilder
    private func row(_ entry: Frontmatter.Entry, index: Int) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text(entry.key)
                .font(Typography.caption.weight(.medium))
                .foregroundStyle(ThemeColor.textTertiary)
                .frame(width: 84, alignment: .leading)
                .padding(.top, 3)
                .accessibilityHidden(true)
            switch entry.value {
            case .scalar(let s):
                scalarField(key: entry.key, value: s)
            case .list(let items):
                chipField(key: entry.key, items: items)
            }
        }
    }

    private func scalarField(key: String, value: String) -> some View {
        let binding = Binding<String>(
            get: { value },
            set: { var fm = frontmatter; fm.setScalar(key, $0); onChange(fm) }
        )
        return TextField(key, text: binding)
            .textFieldStyle(.plain)
            .font(Typography.callout)
            .foregroundStyle(ThemeColor.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(ThemeColor.surfaceHover, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(key): \(value)")
    }

    private func chipField(key: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            FlowLayout(spacing: Spacing.xs) {
                ForEach(items, id: \.self) { item in
                    chip(item) {
                        var fm = frontmatter
                        fm.setList(key, items.filter { $0 != item })
                        onChange(fm)
                    }
                }
                addChip(key: key, items: items)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(key): \(items.joined(separator: ", "))")
    }

    private func chip(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.xxs) {
            Text(text).font(Typography.caption).foregroundStyle(ThemeColor.accent)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(ThemeColor.accentSubtle, in: Capsule())
    }

    private func addChip(key: String, items: [String]) -> some View {
        let binding = Binding<String>(
            get: { newChipText[key] ?? "" },
            set: { newChipText[key] = $0 }
        )
        return TextField("add…", text: binding)
            .textFieldStyle(.plain)
            .font(Typography.caption)
            .frame(width: 64)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(ThemeColor.surfaceHover, in: Capsule())
            .onSubmit {
                let t = (newChipText[key] ?? "").trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty, !items.contains(t) else { newChipText[key] = ""; return }
                var fm = frontmatter
                fm.setList(key, items + [t])
                onChange(fm)
                newChipText[key] = ""
            }
            .accessibilityLabel("Add \(key)")
    }

    private func scalar(_ key: String) -> String? {
        if case .scalar(let s)? = frontmatter[key] { return s }
        return nil
    }
}

// MARK: - FlowLayout
//
// Minimal wrapping layout for the chip rows (tags/aliases).
struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
