import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// The History pane: a per-file commit timeline on the left, the selected
// commit's diff on the right. Selecting a commit loads + shows its diff;
// a one-click "Restore" (confirmed) writes the older revision back as a new
// commit. Wired into HistorySlot as `HistoryView(model: app.history)`.
// Keyboard: ↑/↓ move between commits, ⏎ views the highlighted commit.
// ════════════════════════════════════════════════════════════════════════

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            if app.selectedPath == nil {
                EmptyStateView(icon: "clock.arrow.circlepath", title: "No note selected",
                               message: "Choose a note to see its history.")
            } else if model.isLoading && model.commits.isEmpty {
                LoadingStateView("Loading history…")
            } else if let error = model.errorMessage, model.commits.isEmpty {
                ErrorStateView(message: error) {
                    Task { if let p = app.selectedPath { await model.load(path: p) } }
                }
            } else if model.commits.isEmpty {
                EmptyStateView(icon: "clock", title: "No history yet",
                               message: "This note has no commits.")
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.background)
        .task(id: app.selectedPath) {
            guard let path = app.selectedPath else { return }
            await model.load(path: path)
            if let first = model.commits.first { await model.select(commit: first) }
        }
        .alert("Restore this version?", isPresented: restoreAlertBinding, presenting: model.pendingRestore) { commit in
            Button("Cancel", role: .cancel) { model.pendingRestore = nil }
            Button("Restore") { Task { await model.confirmRestore(commit) } }
        } message: { commit in
            Text("This writes the content from “\(commit.message)” back as a new commit. Nothing is lost — the current version stays in history.")
        }
    }

    private var content: some View {
        HSplitView {
            TimelineList(model: model)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            diffPane
                .frame(minWidth: 360, maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        if model.isLoadingDiff {
            LoadingStateView("Loading diff…")
        } else if let parsed = model.parsedDiff {
            VStack(spacing: 0) {
                diffToolbar
                Divider().overlay(ThemeColor.separator)
                DiffView(parsed: parsed, isFirstCommit: model.diffIsFirstCommit)
            }
        } else {
            EmptyStateView(icon: "rectangle.split.2x1", title: "Select a commit",
                           message: "Pick a version on the left to see what changed.")
        }
    }

    private var diffToolbar: some View {
        HStack(spacing: Spacing.sm) {
            if let commit = selectedCommit {
                Text(commit.commit.prefix(8))
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textSecondary)
                Text(commit.message)
                    .font(Typography.callout)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if let commit = selectedCommit, !isHeadCommit(commit) {
                Button {
                    model.pendingRestore = commit
                } label: {
                    Label("Restore this version", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SvodButtonStyle(.secondary))
                .disabled(model.isRestoring)
                .help("Write this version's content back as a new commit")
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(ThemeColor.surface)
    }

    private var selectedCommit: CommitInfo? {
        model.commits.first { $0.commit == model.selectedCommit }
    }
    private func isHeadCommit(_ commit: CommitInfo) -> Bool {
        commit.commit == model.commits.first?.commit
    }
    private var restoreAlertBinding: Binding<Bool> {
        Binding(get: { model.pendingRestore != nil },
                set: { if !$0 { model.pendingRestore = nil } })
    }
}

// MARK: - Timeline

private struct TimelineList: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    SectionLabel("History", systemImage: "clock.arrow.circlepath")
                        .padding(.horizontal, Spacing.sm)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.xs)

                    ForEach(Array(model.commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(commit: commit,
                                  isSelected: commit.commit == model.selectedCommit,
                                  isHead: index == 0)
                            .id(commit.commit)
                            .onTapGesture { Task { await model.select(commit: commit) } }
                    }
                }
                .padding(Spacing.sm)
            }
            .background(ThemeColor.surface)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, proxy: proxy); return .handled }
            .onKeyPress(.downArrow) { move(1, proxy: proxy); return .handled }
            .onKeyPress(.return) {
                if let c = current { Task { await model.select(commit: c) } }
                return .handled
            }
            .onAppear { focused = true }
            .accessibilityLabel("Commit timeline")
        }
    }

    private var current: CommitInfo? {
        model.commits.first { $0.commit == model.selectedCommit } ?? model.commits.first
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) {
        guard !model.commits.isEmpty else { return }
        let idx = model.commits.firstIndex { $0.commit == model.selectedCommit } ?? 0
        let next = min(max(idx + delta, 0), model.commits.count - 1)
        let commit = model.commits[next]
        Task { await model.select(commit: commit) }
        withAnimation(Motion.quick) { proxy.scrollTo(commit.commit, anchor: .center) }
    }
}

private struct CommitRow: View {
    let commit: CommitInfo
    let isSelected: Bool
    let isHead: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            // Timeline rail: dot + connecting line.
            VStack(spacing: 0) {
                Circle()
                    .fill(ThemeColor.agentColor(for: commit.author))
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(ThemeColor.background, lineWidth: 2))
                    .padding(.top, 4)
                Rectangle()
                    .fill(ThemeColor.separator)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.sm) {
                    Text(commit.author)
                        .font(Typography.callout.weight(.medium))
                        .foregroundStyle(ThemeColor.agentColor(for: commit.author))
                    if isHead {
                        StatusPill("current", tone: .accent, showsDot: false)
                    }
                    Spacer(minLength: 0)
                    Text(relativeTime)
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textTertiary)
                }
                Text(commit.message)
                    .font(Typography.callout)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                Text(commit.commit.prefix(8))
                    .font(Typography.codeSmall)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            .padding(.vertical, Spacing.xs)
            .padding(.trailing, Spacing.sm)
        }
        .padding(.leading, Spacing.sm)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(commit.author), \(relativeTime). \(commit.message).\(isHead ? " Current version." : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var rowBackground: Color {
        if isSelected { return ThemeColor.surfaceSelected }
        if hovering { return ThemeColor.surfaceHover }
        return .clear
    }
    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: commit.date, relativeTo: Date())
    }
}

// MARK: - Previews

#Preview("Timeline + diff") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    return HistoryView(model: app.history)
        .environmentObject(app)
        .frame(width: 1000, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Empty — no note") {
    let app = AppModel(client: MockSvodClient.preview)
    return HistoryView(model: app.history)
        .environmentObject(app)
        .frame(width: 1000, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Loading") {
    let app = AppModel(client: MockSvodClient(behavior: .slow))
    app.selectedPath = "vault/architecture.md"
    return HistoryView(model: app.history)
        .environmentObject(app)
        .frame(width: 1000, height: 560)
        .preferredColorScheme(.dark)
}
