import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Two presentation paths:
//
// 1. ConflictMergeView(conflict:model:) — write 409, presented via ConflictSlot.
//    Dismiss via app.dismissConflict().
//
// 2. ConflictMergeView(item:listModel:client:onDismiss:) — GET /conflicts item.
//    Content arrives inline; dismiss via the onDismiss closure (sheet).
// ════════════════════════════════════════════════════════════════════════

struct ConflictMergeView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var merge: ConflictMergeModel

    /// Non-nil only in the conflicts-list path — called when the sheet should close.
    private let onDismiss: (() -> Void)?

    // MARK: Init — write 409 (existing, via ConflictSlot)
    init(conflict: ConflictBody, model: HistoryModel) {
        _merge = StateObject(wrappedValue: ConflictMergeModel(
            conflict: conflict, client: model.client, app: model.app))
        onDismiss = nil
    }

    // MARK: Init — GET /conflicts item (v0.3.0+, via ConflictsListView sheet)
    init(item: Conflicts.Item, listModel: ConflictsListModel, client: SvodClient,
         onDismiss: @escaping () -> Void) {
        _merge = StateObject(wrappedValue: ConflictMergeModel(
            item: item, listModel: listModel, client: client))
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ThemeColor.separator)
            if merge.isLoading {
                LoadingStateView("Gathering both versions…")
            } else {
                mergeBody(content: merge)
            }
            Divider().overlay(ThemeColor.separator)
            footer
        }
        .frame(width: 920, height: 620)
        .background(ThemeColor.surface)
        .task { await merge.load() }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 18))
                .foregroundStyle(ThemeColor.conflict)
            VStack(alignment: .leading, spacing: 1) {
                Text("Resolve conflict")
                    .font(Typography.headline)
                    .foregroundStyle(ThemeColor.textPrimary)
                Text(merge.path)
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            Spacer()
            StatusPill("sync conflict", tone: .conflict)
        }
        .padding(Spacing.lg)
        .background(ThemeColor.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resolve conflict for \(merge.path).")
    }

    private func mergeBody(content merge: ConflictMergeModel) -> some View {
        VStack(spacing: Spacing.md) {
            // Three read-only reference panes.
            HStack(spacing: Spacing.md) {
                ReferencePane(title: "Base", subtitle: "common ancestor", tone: .neutral,
                              text: merge.base, systemImage: "circle.dashed")
                ReferencePane(title: "Ours", subtitle: "local version", tone: .accent,
                              text: merge.yours, systemImage: "person.crop.circle")
                ReferencePane(title: "Theirs", subtitle: "remote version", tone: .conflict,
                              text: merge.theirs, systemImage: "externaldrive")
            }
            .frame(maxHeight: .infinity)

            // Editable merged result.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    SectionLabel("Merged result", systemImage: "checkmark.seal")
                    Spacer()
                    Button("Keep Ours") { merge.keepYours() }
                        .buttonStyle(SvodButtonStyle(.secondary))
                        .accessibilityHint("Replace the merged result with our local version")
                    Button("Keep Theirs") { merge.keepTheirs() }
                        .buttonStyle(SvodButtonStyle(.secondary))
                        .accessibilityHint("Replace the merged result with the remote version")
                }
                MergeEditor(text: Binding(
                    get: { merge.merged },
                    set: { merge.merged = $0; merge.mergedEdited() }))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(Spacing.lg)
    }

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            if let error = merge.errorMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor.warning)
                Text(error)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(SvodButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            Button {
                Task { if await merge.save() { dismiss() } }
            } label: {
                if merge.isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save merged")
                }
            }
            .buttonStyle(SvodButtonStyle(.primary))
            .keyboardShortcut(.defaultAction)
            .disabled(merge.isSaving || merge.merged.isEmpty)
            .help("Write the merged result, resolving the conflict")
        }
        .padding(Spacing.lg)
        .background(ThemeColor.surface)
    }

    private func dismiss() {
        if let onDismiss { onDismiss() } else { app.dismissConflict() }
    }
}

// MARK: - Reference pane (read-only)

private struct ReferencePane: View {
    let title: String
    let subtitle: String
    let tone: StatusPill.Tone
    let text: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: systemImage).imageScale(.small).foregroundStyle(tone.indicator)
                Text(title).font(Typography.callout.weight(.semibold)).foregroundStyle(ThemeColor.textPrimary)
                Text(subtitle).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                Spacer()
            }
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.sm)
            }
            .background(ThemeColor.editorSurface, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radii.sm, style: .continuous)
                .strokeBorder(ThemeColor.borderSubtle, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(text.isEmpty ? "empty" : text)
    }
}

private extension StatusPill.Tone {
    var indicator: Color {
        switch self {
        case .accent:   ThemeColor.accent
        case .conflict: ThemeColor.conflict
        default:        ThemeColor.textTertiary
        }
    }
}

// MARK: - Merged editor

private struct MergeEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(Typography.code)
            .scrollContentBackground(.hidden)
            .padding(Spacing.sm)
            .background(ThemeColor.editorSurface, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radii.sm, style: .continuous)
                .strokeBorder(ThemeColor.accentMuted, lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Merged result, editable")
    }
}

// MARK: - Previews

#Preview("Conflict — write 409") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    let conflict = ConflictBody(
        path: "vault/architecture.md",
        expected: "a1b2c3",
        current: "z9y8x7",
        currentContent: """
        # Architecture

        Svod is a local, git-backed markdown knowledge base.
        The engine is the single writer — edited by another agent.
        """)
    return ConflictMergeView(conflict: conflict, model: app.history)
        .environmentObject(app)
        .preferredColorScheme(.dark)
}

#Preview("Conflict — from conflicts list") {
    let client = MockSvodClient.preview
    let listModel = ConflictsListModel(client: client)
    // sampleConflict has full base/ours/theirs inline — representative 3-way merge.
    let item = Conflicts.Item(
        path: "vault/architecture.md",
        reasons: ["Concurrent edit on two hosts"],
        base: "# Architecture\n\nSvod is a local, git-backed markdown knowledge base.\n",
        ours: "# Architecture\n\nSvod is a local, git-backed knowledge base.\n\n## Write path\n\n1. Serialize through the write-actor.\n",
        theirs: "# Architecture\n\nSvod is a local, git-backed markdown knowledge base.\n\n## Sync\n\nPeers sync via git push/pull.\n",
        ts: nil)
    return ConflictMergeView(item: item, listModel: listModel, client: client, onDismiss: {})
        .environmentObject(AppModel(client: client))
        .preferredColorScheme(.dark)
}
