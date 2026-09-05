import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Agent Activity (Features/Activity/)
//
// The review inbox: agent commits nobody has looked at yet. Sits at the top of
// the Inspector. Row tap opens the note's History on that commit; ✓ dismisses;
// Revert writes the pre-commit content back as a new commit (confirmed).
// Observes ActivityModel directly so the Inspector body doesn't re-render on
// every feed event.
// ════════════════════════════════════════════════════════════════════════

struct ReviewCard: View {
    @ObservedObject var activity: ActivityModel
    @EnvironmentObject var app: AppModel

    @State private var pendingRevert: SvodEvent?
    /// Per-commit outcome caption after a revert attempt that did not remove the row.
    @State private var notes: [String: String] = [:]
    @State private var reverting: String?

    var body: some View {
        if !activity.pending.isEmpty {
            Card(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    header
                    ForEach(activity.pending) { event in
                        ReviewRow(event: event,
                                  note: notes[event.id],
                                  busy: reverting == event.id,
                                  canRevert: ActivityModel.canRevert(event),
                                  onJump: { jump(event) },
                                  onReviewed: { dismiss(event) },
                                  onRevert: { pendingRevert = event })
                    }
                    Text("Agent commits since the app was last connected.")
                        .font(Typography.caption2)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .padding(.horizontal, Spacing.xs)
                }
            }
            .alert("Revert this change?", isPresented: revertAlertBinding, presenting: pendingRevert) { event in
                Button("Cancel", role: .cancel) { pendingRevert = nil }
                Button("Revert", role: .destructive) { Task { await revert(event) } }
            } message: { event in
                Text("Writes the content from before \(event.data.displayActor)’s change to “\(fileName(event))” back as a new commit. Nothing is lost — the agent’s version stays in history. A note the agent created is moved to the trash.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            SectionLabel("To review", systemImage: "checklist")
            Text("\(activity.pending.count)")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.textTertiary)
                .monospacedDigit()
            Spacer()
            Button("Mark all reviewed") {
                withAnimation(Motion.quick) { activity.markAllReviewed() }
            }
            .buttonStyle(.plain)
            .font(Typography.caption.weight(.medium))
            .foregroundStyle(ThemeColor.accent)
            .accessibilityHint("Clears every pending agent change")
        }
        .padding(.horizontal, Spacing.xs)
    }

    private var revertAlertBinding: Binding<Bool> {
        Binding(get: { pendingRevert != nil }, set: { if !$0 { pendingRevert = nil } })
    }

    private func fileName(_ event: SvodEvent) -> String {
        (event.data.path as NSString?)?.lastPathComponent ?? event.data.path ?? "—"
    }

    /// Open the note with History focused on this very commit, not the newest one.
    private func jump(_ event: SvodEvent) {
        guard let path = event.data.path else { return }
        app.open(path: path)
        app.history.focusCommit = event.data.commit
        app.setCenter(.history)
    }

    private func dismiss(_ event: SvodEvent) {
        notes[event.id] = nil
        withAnimation(Motion.quick) { activity.markReviewed(event) }
    }

    private func revert(_ event: SvodEvent) async {
        pendingRevert = nil
        reverting = event.id
        defer { reverting = nil }
        switch await activity.revert(event) {
        case .reverted, .trashed:
            notes[event.id] = nil
        case .changedSince:
            notes[event.id] = "Changed since — open History to compare."
        case .conflict:
            notes[event.id] = nil   // the 3-way merge sheet is up
        case .failed(let message):
            notes[event.id] = message
        }
    }
}

// MARK: - Row

private struct ReviewRow: View {
    let event: SvodEvent
    let note: String?
    let busy: Bool
    let canRevert: Bool
    let onJump: () -> Void
    let onReviewed: () -> Void
    let onRevert: () -> Void

    @State private var hovering = false

    private var actor: String { event.data.displayActor }
    private var fileName: String {
        (event.data.path as NSString?)?.lastPathComponent ?? event.data.path ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Button(action: onJump) {
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Circle()
                            .fill(ThemeColor.agentColor(for: actor))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: Spacing.xs) {
                                Text(actor)
                                    .font(Typography.callout.weight(.medium))
                                    .foregroundStyle(ThemeColor.agentColor(for: actor))
                                Text(event.data.verb)
                                    .font(Typography.callout)
                                    .foregroundStyle(ThemeColor.textSecondary)
                            }
                            Text(fileName)
                                .font(Typography.caption)
                                .foregroundStyle(ThemeColor.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: Spacing.xs)
                        Text(RelativeTime.string(from: event.date))
                            .font(Typography.caption)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the diff in History")
                .accessibilityLabel("\(actor) \(event.data.verb) \(fileName), \(RelativeTime.string(from: event.date))")
                .accessibilityHint("Opens the diff for this change")

                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Menu {
                        Button { onReviewed() } label: { Label("Mark reviewed", systemImage: "checkmark") }
                        Button { onJump() } label: { Label("Open diff", systemImage: "rectangle.split.2x1") }
                        if canRevert {
                            Divider()
                            Button(role: .destructive) { onRevert() } label: {
                                Label("Revert…", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(ThemeColor.textTertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(fileName)")
                }
            }
            if let note {
                Text(note)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.warning)
                    .padding(.leading, Spacing.md + Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background(hovering ? ThemeColor.surfaceHover : .clear,
                    in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .onHover { hovering = $0 }
    }
}

// MARK: - Toolbar badge

/// Pending count on the inspector toggle. Renders nothing at zero.
struct ReviewBadge: View {
    @ObservedObject var activity: ActivityModel

    var body: some View {
        if !activity.pending.isEmpty {
            Text("\(activity.pending.count)")
                .font(Typography.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(ThemeColor.accent, in: Capsule())
                .offset(x: 7, y: -7)
                .accessibilityLabel("\(activity.pending.count) agent changes to review")
        }
    }
}

/// The Inspector's no-selection state: the review inbox when there is one, the
/// plain empty state otherwise. Observes the model itself so the Inspector body
/// (which observes only AppModel) doesn't have to.
struct ReviewOrEmptyState: View {
    @ObservedObject var activity: ActivityModel

    var body: some View {
        if activity.pending.isEmpty {
            EmptyStateView(icon: "info.circle", title: "No note selected",
                           message: "Open a note to see its backlinks, history and agent activity.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ReviewCard(activity: activity)
                    Text("Open a note to see its backlinks, history and agent activity.")
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .padding(.horizontal, Spacing.xs)
                }
                .padding(Spacing.pane)
            }
        }
    }
}

// MARK: - Previews
#Preview("Review card") {
    let app = AppModel(client: MockSvodClient.preview)
    app.engine.startConnecting()
    return ScrollView { ReviewCard(activity: app.activity).padding(Spacing.pane) }
        .environmentObject(app)
        .frame(width: 320, height: 420)
}
