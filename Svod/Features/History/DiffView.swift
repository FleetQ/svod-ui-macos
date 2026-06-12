import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Renders a parsed diff. Side-by-side is the primary presentation; a unified
// fallback is offered via the same parsed model for narrow widths. Monospace,
// line-numbered, horizontally scrollable, VoiceOver-labeled.
// ════════════════════════════════════════════════════════════════════════

struct DiffView: View {
    let parsed: ParsedDiff
    let isFirstCommit: Bool
    @AppStorage("history.diffLayout") private var sideBySide = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ThemeColor.separator)
            if parsed.isEmpty {
                EmptyStateView(icon: "equal", title: "No textual change",
                               message: "This commit didn't change the text of this note.")
            } else if sideBySide {
                SideBySideDiff(rows: parsed.rows)
            } else {
                UnifiedDiff(lines: parsed.lines)
            }
        }
        .background(ThemeColor.editorSurface)
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            if isFirstCommit {
                StatusPill("First commit", tone: .accent, showsDot: false)
            }
            HStack(spacing: Spacing.xs) {
                Text("+\(parsed.addCount)").foregroundStyle(ThemeColor.diffAdd)
                Text("−\(parsed.delCount)").foregroundStyle(ThemeColor.diffDel)
            }
            .font(Typography.codeSmall)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(parsed.addCount) added, \(parsed.delCount) removed")

            Spacer()

            Picker("", selection: $sideBySide) {
                Image(systemName: "rectangle.split.2x1").tag(true)
                    .accessibilityLabel("Side by side")
                Image(systemName: "list.bullet").tag(false)
                    .accessibilityLabel("Unified")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Toggle side-by-side / unified diff")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(ThemeColor.surface)
    }
}

// MARK: - Side-by-side

private struct SideBySideDiff: View {
    let rows: [SideBySideRow]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if isSpanning(row) {
                        // meta/hunk header spans the full width
                        DiffCell(line: row.left, side: .new, showOldNumber: false, spanning: true)
                    } else {
                        HStack(spacing: 0) {
                            DiffCell(line: row.left, side: .old, showOldNumber: true, spanning: false)
                                .frame(width: 380, alignment: .leading)
                            Rectangle().fill(ThemeColor.separator).frame(width: 1)
                            DiffCell(line: row.right, side: .new, showOldNumber: false, spanning: false)
                                .frame(width: 380, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func isSpanning(_ row: SideBySideRow) -> Bool {
        if let l = row.left, l.kind == .meta || l.kind == .hunk { return true }
        return false
    }
}

private enum DiffSide { case old, new }

private struct DiffCell: View {
    let line: DiffLine?
    let side: DiffSide
    let showOldNumber: Bool
    let spanning: Bool

    var body: some View {
        if let line {
            HStack(spacing: Spacing.sm) {
                Text(gutter(for: line))
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.diffMeta)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(marker(for: line))
                    .font(Typography.code)
                    .foregroundStyle(line.color)
                    .frame(width: 8, alignment: .center)
                    .accessibilityHidden(true)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(Typography.code)
                    .foregroundStyle(line.kind == .meta ? ThemeColor.diffMeta : line.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 1)
            .frame(maxWidth: spanning ? .infinity : nil, alignment: .leading)
            .background(line.background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.accessibilityLabel)
        } else {
            // Blank gutter for an unpaired add/del on the other side.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 18)
                .background(ThemeColor.surfaceHover.opacity(0.4))
                .accessibilityHidden(true)
        }
    }

    private func marker(for line: DiffLine) -> String {
        switch line.kind { case .add: "+"; case .del: "−"; default: " " }
    }
    private func gutter(for line: DiffLine) -> String {
        switch side {
        case .old: line.oldNumber.map(String.init) ?? ""
        case .new: line.newNumber.map(String.init) ?? ""
        }
    }
}

// MARK: - Unified fallback

private struct UnifiedDiff: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: Spacing.sm) {
                        Text(line.oldNumber.map(String.init) ?? "")
                            .frame(width: 32, alignment: .trailing)
                        Text(line.newNumber.map(String.init) ?? "")
                            .frame(width: 32, alignment: .trailing)
                        Text(symbol(line) + line.text)
                            .foregroundStyle(line.kind == .meta ? ThemeColor.diffMeta : line.color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    .font(Typography.code)
                    .foregroundStyle(ThemeColor.diffMeta)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 1)
                    .background(line.background)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.accessibilityLabel)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private func symbol(_ line: DiffLine) -> String {
        switch line.kind { case .add: "+ "; case .del: "− "; case .hunk: ""; case .meta: ""; case .context: "  " }
    }
}

#Preview("Diff — side by side") {
    DiffView(parsed: ParsedDiff.parse(MockSvodClient.sampleDiff), isFirstCommit: false)
        .frame(width: 820, height: 420)
        .background(ThemeColor.background)
}

#Preview("Diff — first commit (all added)") {
    DiffView(parsed: ParsedDiff.allAdded("# Architecture\n\nThe engine is the single writer.\nIt guards the source of truth.\n"),
             isFirstCommit: true)
        .frame(width: 820, height: 420)
        .background(ThemeColor.background)
}
