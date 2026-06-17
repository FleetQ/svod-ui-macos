import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Lists sync conflicts from GET /api/v1/conflicts (v0.3.0+). Each row opens
// ConflictMergeView as a sheet so the user can hand-merge base/ours/theirs
// content inline and commit via resolveConflict. Reloads on app.reloadEpoch
// (bumped on vault switch). Empty state is shown when there are no conflicts.
// ════════════════════════════════════════════════════════════════════════

struct ConflictsListView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: ConflictsListModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(ThemeColor.separator)
            content
        }
        .background(ThemeColor.surface)
        .task(id: app.reloadEpoch) { await model.load() }
        .sheet(item: $model.activeItem) { item in
            ConflictMergeView(
                item: item,
                listModel: model,
                client: model.client,
                onDismiss: { model.activeItem = nil }
            )
            .environmentObject(app)
        }
    }

    // MARK: -

    private var toolbar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 15))
                .foregroundStyle(model.items.isEmpty ? ThemeColor.textTertiary : ThemeColor.conflict)
            Text("Sync Conflicts")
                .font(Typography.headline)
                .foregroundStyle(ThemeColor.textPrimary)
            if !model.items.isEmpty {
                StatusPill("\(model.items.count)", tone: .conflict, showsDot: false)
            }
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(ThemeColor.textSecondary)
                .help("Refresh conflicts list")
                .accessibilityLabel("Refresh conflicts")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            ErrorStateView(message: error) { Task { await model.load() } }
        } else if model.isLoading && model.items.isEmpty {
            LoadingStateView("Loading conflicts…")
        } else if model.items.isEmpty {
            EmptyStateView(icon: "checkmark.seal", title: "No conflicts",
                           message: "All vaults are in sync.")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    ConflictRow(item: item) {
                        model.activeItem = item
                    }
                    Divider().overlay(ThemeColor.separator).padding(.leading, Spacing.lg)
                }
            }
        }
    }

}

// MARK: - Conflict row

private struct ConflictRow: View {
    let item: Conflicts.Item
    let onResolve: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onResolve) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 14))
                    .foregroundStyle(ThemeColor.conflict)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.path)
                        .font(Typography.callout.weight(.medium))
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(1)
                    if let reasons = item.reasons, !reasons.isEmpty {
                        Text(reasons.joined(separator: " \u{00B7} "))
                            .font(Typography.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Indicate which sides have content.
                HStack(spacing: Spacing.xs) {
                    sideIndicator("B", present: item.base != nil)
                    sideIndicator("O", present: item.ours != nil)
                    sideIndicator("T", present: item.theirs != nil)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? ThemeColor.surfaceHover : Color.clear)
        .onHover { hovering = $0 }
        .accessibilityLabel("Conflict in \(item.path). Tap to resolve.")
        .accessibilityAddTraits(.isButton)
    }

    private func sideIndicator(_ letter: String, present: Bool) -> some View {
        Text(letter)
            .font(Typography.codeSmall.weight(.semibold))
            .foregroundStyle(present ? ThemeColor.textSecondary : ThemeColor.textTertiary.opacity(0.4))
            .frame(width: 14)
    }
}

// MARK: - Preview

#Preview("Conflicts list — with items") {
    let client = MockSvodClient.preview
    let model = ConflictsListModel(client: client)
    return ConflictsListView(model: model)
        .environmentObject(AppModel(client: client))
        .frame(width: 380, height: 480)
        .preferredColorScheme(.dark)
        .task { await model.load() }
}

#Preview("Conflicts list — empty") {
    let client = MockSvodClient(behavior: .empty)
    let model = ConflictsListModel(client: client)
    return ConflictsListView(model: model)
        .environmentObject(AppModel(client: client))
        .frame(width: 380, height: 480)
        .preferredColorScheme(.dark)
        .task { await model.load() }
}
