import SwiftUI

// Memory — the "recall" panel (engine ≥ contract 0.22.0). Surfaces the engine's
// capture→distill loop: a Stop hook captures each Claude Code session into
// messy/sessions/ (kept out of search/recall), a nightly job distills them into
// durable notes, and recurring cross-session patterns surface here as skill/tool
// proposals. This panel is read-only except for resolving proposals — and accepting
// one only FLAGS it (suggestions-over-automation); nothing is created automatically.
// Degrades to a calm note on engines without /memory (apiVersion < 0.22.0).

struct MemorySettingsView: View {
    @EnvironmentObject var app: AppModel

    @State private var dashboard: MemoryDashboard?
    @State private var sessions: [MemorySession] = []
    @State private var proposals: [MemoryProposal] = []
    @State private var unavailable = false
    @State private var busy = false
    @State private var statusMsg: String?

    private var client: SvodClient { app.client }

    var body: some View {
        Form {
            if unavailable {
                Section {
                    Label("Memory needs a newer Svod engine.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("Update the engine to contract 0.22.0+ to capture sessions and distill them into durable memory.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if app.engine.supportsMemoryReview {
                    MemoryReviewSection(model: MemoryReviewModel(client: client)) {
                        Task { dashboard = try? await client.memoryDashboard() }
                    }
                    .id(app.vault.activeVault?.id ?? "default")
                }
                dashboardSection
                proposalsSection
                sessionsSection
            }
            if let statusMsg {
                Section { Text(statusMsg).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    // MARK: overview

    @ViewBuilder private var dashboardSection: some View {
        Section("Overview") {
            if let d = dashboard, d.hasActivity {
                LabeledContent("Sessions captured", value: "\(d.sessionsCaptured)")
                LabeledContent("Distilled", value: "\(d.sessionsDistilled) of \(d.sessionsCaptured)")
                LabeledContent("Durable notes written", value: "\(d.notesWritten)")
                LabeledContent("Compression",
                               value: d.compressionRatio > 0 ? String(format: "%.1f×", d.compressionRatio) : "—")
                LabeledContent("Last distilled",
                               value: d.lastDistillAt.map { RelativeTime.string(from: Self.msDate($0)) } ?? "never")
                if let waiting = d.awaitingReview {
                    LabeledContent("Awaiting review", value: "\(waiting)")
                }
            } else {
                Text("No sessions captured yet. When a Claude Code session ends, the capture hook stores it here; the nightly job then distills it into durable memory.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: proposals inbox

    @ViewBuilder private var proposalsSection: some View {
        Section("Proposals") {
            let open = proposals.filter { $0.isOpen }
            if open.isEmpty {
                Text("No open proposals. When the distiller spots a pattern that recurs across sessions, it suggests a skill or tool here for you to approve.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(open) { p in
                ProposalRow(proposal: p,
                            onAccept: { Task { await resolve(p, "accept") } },
                            onReject: { Task { await resolve(p, "reject") } })
                    .disabled(busy)
            }
        }
    }

    // MARK: recent sessions

    @ViewBuilder private var sessionsSection: some View {
        Section("Recent sessions") {
            if sessions.isEmpty {
                Text("Captured sessions will appear here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(sessions.prefix(8)) { s in SessionRow(session: s) }
        }
    }

    // MARK: actions

    private func load() async {
        do {
            async let d = client.memoryDashboard()
            async let s = client.memorySessions(distilled: nil, limit: 20)
            async let p = client.memoryProposals(status: nil)
            dashboard = try await d
            sessions = try await s
            proposals = try await p
            unavailable = false
        } catch let e as SvodClientError where e.isNotImplemented { unavailable = true }
        catch let e as SvodClientError where isNotFound(e) { unavailable = true }
        catch let e as SvodClientError where e.isOffline { _ = e }   // keep last good data
        catch let e as SvodClientError { statusMsg = e.errorDescription }
        catch { statusMsg = error.localizedDescription }
    }

    private func resolve(_ p: MemoryProposal, _ action: String) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            let updated = try await client.resolveProposal(id: p.id, action: action)
            if let i = proposals.firstIndex(where: { $0.id == p.id }) { proposals[i] = updated }
            dashboard = try? await client.memoryDashboard()   // refresh the open-proposal count
        } catch let e as SvodClientError where isNotFound(e) {
            await load()                                      // already resolved elsewhere — refresh
        } catch let e as SvodClientError { statusMsg = e.errorDescription }
        catch { statusMsg = error.localizedDescription }
    }

    private func isNotFound(_ e: SvodClientError) -> Bool {
        if case .notFound = e { return true }
        if case .http(404, _) = e { return true }
        return false
    }

    private static func msDate(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}

// MARK: - Rows

/// Split out so the model is created against the live client once per vault (`.id(vault)`).
private struct MemoryReviewSection: View {
    @StateObject var model: MemoryReviewModel
    var onChange: () -> Void
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Section {
            if model.loaded && model.items.isEmpty && model.acted.isEmpty {
                Text("Nothing to review. When an agent remembers a fact or a policy, it waits here until you approve it; until then search and recall leave it out.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(ThemeColor.warning)
            }
            ForEach(model.acted) { entry in
                ActedRow(entry: entry) { Task { await model.undo(entry) } }
                    .disabled(model.busy.contains(entry.item.path))
            }
            ForEach(model.items) { item in
                ReviewRow(item: item,
                          onApprove: { Task { await model.approve(item) } },
                          onDecline: { Task { await model.decline(item) } },
                          onOpen: { app.open(path: $0) })
                    .disabled(model.busy.contains(item.path))
            }
            if model.total > model.items.count {
                Text("Showing \(model.items.count) of \(model.total).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text(model.loaded ? "Awaiting review (\(model.total))" : "Awaiting review")
        }
        .task {
            model.onChange = onChange
            await model.load()
        }
    }
}

private struct ReviewRow: View {
    let item: MemoryReviewItem
    let onApprove: () -> Void
    let onDecline: () -> Void
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(item.title).fontWeight(.medium).lineLimit(2)
                Spacer()
                if item.needsReview { StatusPill("Needs review", tone: .warning, showsDot: false) }
                if let type = item.type { StatusPill(type.capitalized, tone: .accent, showsDot: false) }
            }
            if !item.excerpt.isEmpty {
                Text(item.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if let contradicts = item.contradicts {
                linkButton("Contradicts", contradicts)
            }
            if let supersedes = item.supersedes {
                linkButton("Supersedes", supersedes)
            }
            HStack(spacing: Spacing.sm) {
                if let subject = item.subject {
                    Text(subject).font(.caption).foregroundStyle(.secondary)
                }
                if let confidence = item.confidence {
                    Text("confidence \(Int((confidence * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { onOpen(item.path) }.buttonStyle(.borderless)
                Button("Decline", role: .destructive, action: onDecline).buttonStyle(.borderless)
                Button("Approve", action: onApprove).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func linkButton(_ label: String, _ raw: String) -> some View {
        let path = MemoryBadgesBar.linkPath(raw)
        return Button { onOpen(path) } label: {
            Text("\(label) \((path as NSString).lastPathComponent)")
                .font(.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(ThemeColor.link)
        }
        .buttonStyle(.plain)
        .help(path)
    }
}

private struct ActedRow: View {
    let entry: MemoryReviewModel.Acted
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(entry.item.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            StatusPill(entry.action == .approve ? "Approved" : "Declined",
                       tone: entry.action == .approve ? .success : .danger, showsDot: false)
            Button("Undo", action: onUndo).buttonStyle(.borderless)
        }
    }
}

private struct ProposalRow: View {
    let proposal: MemoryProposal
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(proposal.title).fontWeight(.medium)
                Spacer()
                StatusPill(proposal.kind.capitalized, tone: .accent, showsDot: false)
                StatusPill(proposal.scope.capitalized,
                           tone: proposal.scope == "global" ? .warning : .neutral, showsDot: false)
            }
            if !proposal.rationale.isEmpty {
                Text(proposal.rationale).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.sm) {
                Text("confidence \(Int((proposal.confidence * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary)
                if !proposal.sourceSessions.isEmpty {
                    Text("· \(proposal.sourceSessions.count) sessions")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reject", role: .destructive, action: onReject).buttonStyle(.borderless)
                Button("Accept", action: onAccept).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionRow: View {
    let session: MemorySession
    private static let bytes = ByteCountFormatter()

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project ?? "unknown project").fontWeight(.medium)
                Text(RelativeTime.string(from: Date(timeIntervalSince1970: Double(session.endedAt) / 1000)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Self.bytes.string(fromByteCount: Int64(session.bytes)))
                .font(.caption).monospaced().foregroundStyle(.secondary)
            StatusPill(session.distilled ? "distilled" : "raw",
                       tone: session.distilled ? .success : .neutral, showsDot: false)
        }
    }
}

#Preview("Memory") {
    MemorySettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 720, height: 560)
}
