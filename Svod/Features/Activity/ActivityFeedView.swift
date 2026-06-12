import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Agent Activity (Features/Activity/)
//
// The live agent feed. Per-agent colored identity, verb + path + relative time,
// conflict items styled differently, jump-to-diff on click. Gentle spring
// entrances (Motion.arrive drives the model's insert; Motion.feedInsertion is
// the row transition). Used standalone AND embedded in the Inspector, so it
// takes a `compact` flag to drop its own header/padding when nested.
// ════════════════════════════════════════════════════════════════════════

struct ActivityFeedView: View {
    @ObservedObject var model: ActivityModel
    @EnvironmentObject var app: AppModel

    /// When embedded (e.g. the Inspector card) we drop the pane header + outer
    /// padding so the host card owns the chrome.
    var compact = false
    /// Optional pre-filtered feed (the Inspector passes per-note events). When
    /// nil we render the whole feed.
    var items: [SvodEvent]? = nil

    private var feed: [SvodEvent] { items ?? model.feed }

    var body: some View {
        Group {
            if compact {
                content
            } else {
                VStack(spacing: 0) {
                    ToolbarSurface {
                        SectionLabel("Agent Activity", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        if !model.feed.isEmpty {
                            Text("\(model.feed.count)")
                                .font(Typography.caption)
                                .foregroundStyle(ThemeColor.textTertiary)
                        }
                    }
                    content
                }
                .background(ThemeColor.surface)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if feed.isEmpty {
            EmptyStateView(icon: "dot.radiowaves.left.and.right",
                           title: "Quiet",
                           message: "No recent agent activity.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.xxs) {
                    ForEach(feed) { event in
                        ActivityRow(event: event) { jump(to: event) }
                            .transition(Motion.feedInsertion)
                    }
                }
                .padding(compact ? EdgeInsets() : EdgeInsets(top: Spacing.sm, leading: Spacing.sm,
                                                             bottom: Spacing.sm, trailing: Spacing.sm))
            }
            .accessibilityLabel("Agent activity feed")
        }
    }

    /// An item with a commit jumps to its diff: open the note, show history.
    private func jump(to event: SvodEvent) {
        guard let path = event.data.path else { return }
        app.open(path: path)
        app.setCenter(.history)
    }
}

// MARK: - Row
private struct ActivityRow: View {
    let event: SvodEvent
    let onJump: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var isConflict: Bool { event.type == .conflict }
    private var actor: String { event.data.displayActor }
    private var fileName: String {
        (event.data.path as NSString?)?.lastPathComponent ?? event.data.path ?? "—"
    }
    private var identityColor: Color {
        isConflict ? ThemeColor.conflict : ThemeColor.agentColor(for: actor)
    }

    var body: some View {
        Button(action: onJump) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                identityDot
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.xs) {
                        Text(actor)
                            .font(Typography.callout.weight(.medium))
                            .foregroundStyle(identityColor)
                        Text(verbText)
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
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
            .overlay(alignment: .leading) {
                if isConflict {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ThemeColor.conflict)
                        .frame(width: 2)
                        .padding(.vertical, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(event.data.path.map { "Jump to diff for \($0)" } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(event.data.path != nil ? "Opens the diff for this note" : "")
        .accessibilityAddTraits(.isButton)
    }

    private var identityDot: some View {
        Circle()
            .fill(identityColor)
            .frame(width: 7, height: 7)
            .padding(.top, 5)
            .opacity(reduceMotion ? 1 : 1) // dot is static; calm
    }

    private var verbText: String {
        isConflict ? "conflict on" : event.data.verb
    }

    private var rowBackground: Color {
        if hovering { return ThemeColor.surfaceHover }
        if isConflict { return ThemeColor.conflictSubtle }
        return .clear
    }

    /// "agent friday wrote architecture.md, 2 minutes ago"
    private var accessibilityLabel: String {
        let lead = isConflict ? "conflict on" : "agent \(actor) \(event.data.verb)"
        return "\(lead) \(fileName), \(RelativeTime.string(from: event.date))"
    }
}

// MARK: - Previews
#Preview("Feed — live") {
    let app = AppModel(client: MockSvodClient.preview)
    app.engine.startConnecting()
    return ActivityFeedView(model: app.activity)
        .environmentObject(app)
        .frame(width: 320, height: 460)
}

#Preview("Feed — empty") {
    let app = AppModel(client: MockSvodClient.empty)
    return ActivityFeedView(model: app.activity)
        .environmentObject(app)
        .frame(width: 320, height: 460)
}
