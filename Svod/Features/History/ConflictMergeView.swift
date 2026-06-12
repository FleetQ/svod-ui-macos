import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// The safe-merge surface presented on a write 409. Three read-only reference
// panes (Base / Yours / Theirs) plus an editable merged result. The user never
// touches git: "Keep Yours" / "Keep Theirs" seed the result, hand-edits are
// free, and "Save merged" writes on top of Theirs so nothing is silently lost.
// Presented via ConflictSlot as `ConflictMergeView(conflict:model:)`.
// ════════════════════════════════════════════════════════════════════════

struct ConflictMergeView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var merge: ConflictMergeModel

    init(conflict: ConflictBody, model: HistoryModel) {
        // `model` is accepted to match the integration signature; the merge state
        // lives in its own model so this view fully owns the 3-way buffer.
        _merge = StateObject(wrappedValue: ConflictMergeModel(
            conflict: conflict, client: model.client, app: model.app))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ThemeColor.separator)
            if merge.isLoading {
                LoadingStateView("Gathering both versions…")
            } else {
                body(content: merge)
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
                Text(merge.conflict.path)
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textSecondary)
            }
            Spacer()
            StatusPill("changed on disk", tone: .conflict)
        }
        .padding(Spacing.lg)
        .background(ThemeColor.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resolve conflict for \(merge.conflict.path). This note changed on disk.")
    }

    private func body(content merge: ConflictMergeModel) -> some View {
        VStack(spacing: Spacing.md) {
            // Three reference panes.
            HStack(spacing: Spacing.md) {
                ReferencePane(title: "Base", subtitle: "common ancestor", tone: .neutral,
                              text: merge.base, systemImage: "circle.dashed")
                ReferencePane(title: "Yours", subtitle: "your edit", tone: .accent,
                              text: merge.yours, systemImage: "person.crop.circle")
                ReferencePane(title: "Theirs", subtitle: "changed on disk", tone: .conflict,
                              text: merge.theirs, systemImage: "externaldrive")
            }
            .frame(maxHeight: .infinity)

            // Editable merged result.
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    SectionLabel("Merged result", systemImage: "checkmark.seal")
                    Spacer()
                    Button("Keep Yours") { merge.keepYours() }
                        .buttonStyle(SvodButtonStyle(.secondary))
                        .accessibilityHint("Replace the merged result with your edit")
                    Button("Keep Theirs") { merge.keepTheirs() }
                        .buttonStyle(SvodButtonStyle(.secondary))
                        .accessibilityHint("Replace the merged result with the version on disk")
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
            Button("Cancel") { app.dismissConflict() }
                .buttonStyle(SvodButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)
            Button {
                Task { if await merge.save() { app.dismissConflict() } }
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
            .help("Write the merged result on top of the version on disk")
        }
        .padding(Spacing.lg)
        .background(ThemeColor.surface)
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

// MARK: - Preview

#Preview("Conflict — 3-way merge") {
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
