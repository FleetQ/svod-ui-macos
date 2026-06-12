import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Inspector (Features/Inspector/)
//
// Context for the open note: incoming/unresolved links, a read-only history
// summary, and the per-note agent activity. Loads link + history data with
// `.task(id: app.selectedPath)` so switching notes refreshes it; per-note
// activity comes live from ActivityModel (no fetch needed). Empty when nothing
// is selected.
// ════════════════════════════════════════════════════════════════════════

struct InspectorView: View {
    @EnvironmentObject var app: AppModel

    @State private var links: FileLinks?
    @State private var commits: [CommitInfo] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let path = app.selectedPath {
                loaded(path: path)
            } else {
                EmptyStateView(icon: "info.circle", title: "No note selected",
                               message: "Open a note to see its backlinks, history and agent activity.")
            }
        }
        .background(ThemeColor.surface)
        .task(id: app.selectedPath) { await loadContext() }
    }

    private func loaded(path: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header(path: path)
                backlinksCard
                historyCard(path: path)
                activityCard(path: path)
            }
            .padding(Spacing.pane)
        }
    }

    // MARK: header
    private func header(path: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text((path as NSString).lastPathComponent)
                .font(Typography.title3)
                .foregroundStyle(ThemeColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(path)
                .font(Typography.codeSmall)
                .foregroundStyle(ThemeColor.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Inspecting \((path as NSString).lastPathComponent)")
    }

    // MARK: backlinks
    private var backlinksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel("Backlinks", systemImage: "arrow.uturn.left")
                if isLoading && links == nil {
                    inlineLoading
                } else if let links {
                    if links.backlinks.isEmpty && links.unresolved.isEmpty {
                        emptyHint("No notes link here yet.")
                    } else {
                        ForEach(links.backlinks, id: \.self) { source in
                            LinkRow(label: (source as NSString).lastPathComponent,
                                    sub: source, resolved: true) { app.open(path: source) }
                        }
                        if !links.unresolved.isEmpty {
                            ForEach(links.unresolved, id: \.self) { target in
                                LinkRow(label: target, sub: "unresolved", resolved: false, action: nil)
                            }
                        }
                    }
                } else if errorMessage != nil {
                    emptyHint("Couldn't load links.")
                }
            }
        }
    }

    // MARK: history summary
    private func historyCard(path: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    SectionLabel("Recent History", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if !commits.isEmpty {
                        Button("Open") { app.setCenter(.history) }
                            .buttonStyle(.plain)
                            .font(Typography.caption.weight(.medium))
                            .foregroundStyle(ThemeColor.accent)
                            .accessibilityHint("Opens the full history timeline")
                    }
                }
                if isLoading && commits.isEmpty {
                    inlineLoading
                } else if commits.isEmpty {
                    emptyHint("No commits yet.")
                } else {
                    ForEach(commits.prefix(5)) { commit in
                        CommitMiniRow(commit: commit) { app.setCenter(.history) }
                    }
                }
            }
        }
    }

    // MARK: per-note agent activity
    private func activityCard(path: String) -> some View {
        let events = app.activity.events(for: path)
        return Card(padding: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel("Agent Activity", systemImage: "dot.radiowaves.left.and.right")
                    .padding(.horizontal, Spacing.xs)
                if events.isEmpty {
                    emptyHint("No agent activity for this note.")
                        .padding(.horizontal, Spacing.xs)
                } else {
                    ActivityFeedView(model: app.activity, compact: true, items: events)
                        .environmentObject(app)
                        .frame(maxHeight: 220)
                }
            }
        }
    }

    // MARK: shared bits
    private var inlineLoading: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Loading…").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(ThemeColor.textTertiary)
    }

    // MARK: load
    private func loadContext() async {
        guard let path = app.selectedPath else {
            links = nil; commits = []; errorMessage = nil; return
        }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            async let linksResult = app.client.fileLinks(path: path)
            async let historyResult = app.client.history(path: path, max: 5)
            self.links = try await linksResult
            self.commits = try await historyResult
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Link row
private struct LinkRow: View {
    let label: String
    let sub: String
    let resolved: Bool
    let action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        let content = HStack(spacing: Spacing.sm) {
            Image(systemName: resolved ? "arrow.uturn.left" : "link.badge.plus")
                .imageScale(.small)
                .foregroundStyle(resolved ? ThemeColor.link : ThemeColor.linkUnresolved)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(Typography.callout)
                    .foregroundStyle(resolved ? ThemeColor.textPrimary : ThemeColor.linkUnresolved)
                    .lineLimit(1).truncationMode(.middle)
                Text(sub)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background(hovering && action != nil ? ThemeColor.surfaceHover : .clear,
                    in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .contentShape(Rectangle())

        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .accessibilityHint("Opens \(label)")
            } else {
                content
                    .accessibilityLabel("Unresolved link \(label)")
            }
        }
    }
}

// MARK: - Commit mini row
private struct CommitMiniRow: View {
    let commit: CommitInfo
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(ThemeColor.agentColor(for: commit.author))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(commit.message)
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: Spacing.xs) {
                        Text(commit.author).foregroundStyle(ThemeColor.textSecondary)
                        Text("·").foregroundStyle(ThemeColor.textTertiary)
                        Text(RelativeTime.string(from: commit.date)).foregroundStyle(ThemeColor.textTertiary)
                    }
                    .font(Typography.caption2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xs)
            .background(hovering ? ThemeColor.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(commit.author) — \(commit.message), \(RelativeTime.string(from: commit.date))")
        .accessibilityHint("Opens the history timeline")
    }
}

// MARK: - Previews
#Preview("Inspector — selection") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    app.engine.startConnecting()
    return InspectorView()
        .environmentObject(app)
        .frame(width: 300, height: 640)
}

#Preview("Inspector — empty") {
    let app = AppModel(client: MockSvodClient.preview)
    return InspectorView()
        .environmentObject(app)
        .frame(width: 300, height: 640)
}
