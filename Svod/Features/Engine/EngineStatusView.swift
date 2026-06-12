import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Engine surface (Features/Engine/)
//
// Connection state + the prominent "Start Svod" button, progress during
// start/connect, error display, and the engine's meta (vault, embedder, index,
// write metrics) as calm cards. Self-contained so the integrator can drop it in
// a toolbar popover or a sheet (recommended: a toolbar StatusPill that presents
// this in a popover).
// ════════════════════════════════════════════════════════════════════════

struct EngineStatusView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var model: EngineModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            stateBody
        }
        .padding(Spacing.lg)
        .frame(width: 340)
        .background(ThemeColor.surface)
    }

    // MARK: header — title + live pill
    private var header: some View {
        HStack {
            Text("Svod Engine")
                .font(Typography.headline)
                .foregroundStyle(ThemeColor.textPrimary)
            Spacer()
            StatusPill(app.connection.label,
                       tone: app.connection.pillTone,
                       pulses: isBusy)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Svod engine \(app.connection.label)")
    }

    private var isBusy: Bool {
        switch app.connection {
        case .starting, .connecting: return true
        default: return false
        }
    }

    // MARK: state-driven body
    @ViewBuilder
    private var stateBody: some View {
        switch app.connection {
        case .connected:
            metaCards
        case .starting, .connecting:
            startingState
        case .error(let message):
            errorState(message)
        case .disconnected:
            offlineState
        }
    }

    // MARK: connected — meta
    private var metaCards: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let settings = model.settings {
                Card(padding: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SectionLabel("Vault", systemImage: "externaldrive")
                        MetaRow(label: "Path", value: settings.vaultPath, mono: true)
                        MetaRow(label: "Host", value: settings.host, mono: true)
                        MetaRow(label: "API", value: settings.apiVersion)
                    }
                }
            }
            embedderCard
            indexCard
            metricsCard
            Button("Restart Engine") { Task { await model.start() } }
                .buttonStyle(SvodButtonStyle(.secondary))
                .accessibilityHint("Kickstarts the engine and reconnects")
        }
    }

    @ViewBuilder
    private var embedderCard: some View {
        if let settings = model.settings {
            Card(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionLabel("Embedder", systemImage: "cpu")
                    MetaRow(label: "Provider", value: settings.embedderProvider)
                    if let m = settings.embedderModel {
                        MetaRow(label: "Model", value: m, mono: true)
                    }
                    if let dim = settings.embedderDim {
                        MetaRow(label: "Dimensions", value: "\(dim)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var indexCard: some View {
        if let index = model.indexStatus {
            Card(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionLabel("Index", systemImage: "magnifyingglass")
                    MetaRow(label: "Documents", value: "\(index.docCount)")
                    if let head = index.headIndexed {
                        MetaRow(label: "Head", value: String(head.prefix(8)), mono: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var metricsCard: some View {
        if let metrics = model.metrics {
            Card(padding: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionLabel("Writes", systemImage: "square.and.pencil")
                    MetaRow(label: "Total", value: "\(metrics.write.count)")
                    MetaRow(label: "Avg", value: String(format: "%.1f ms", metrics.write.avgMs))
                    MetaRow(label: "Queue", value: "\(metrics.queueDepth)")
                    if metrics.conflicts > 0 {
                        MetaRow(label: "Conflicts", value: "\(metrics.conflicts)", tone: .conflict)
                    }
                }
            }
        }
    }

    // MARK: starting / connecting
    private var startingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
                .controlSize(.regular)
            Text(app.connection == .starting ? "Starting the engine…" : "Connecting…")
                .font(Typography.callout)
                .foregroundStyle(ThemeColor.textSecondary)
            Text("This usually takes a few seconds.")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Engine starting")
    }

    // MARK: error
    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ThemeColor.danger)
                Text(model.startError ?? message)
                    .font(Typography.callout)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Start Svod") { Task { await model.start() } }
                .buttonStyle(SvodButtonStyle(.primary))
                .accessibilityHint("Tries to start the engine again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Engine error. \(model.startError ?? message)")
    }

    // MARK: disconnected / offline
    private var offlineState: some View {
        OfflineStateView(endpoint: app.client.baseURL.absoluteString) {
            Task { await model.start() }
        }
        .frame(minHeight: 200)
    }
}

// MARK: - Meta row
private struct MetaRow: View {
    let label: String
    let value: String
    var mono = false
    var tone: StatusPill.Tone? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.textTertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(mono ? Typography.codeSmall : Typography.caption)
                .foregroundStyle(tone == .conflict ? ThemeColor.conflict : ThemeColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Previews
#Preview("Engine — connected") {
    let app = AppModel(client: MockSvodClient.preview)
    app.connection = .connected
    Task { await app.engine.loadMeta() }
    return EngineStatusView(model: app.engine)
        .environmentObject(app)
}

#Preview("Engine — offline") {
    let app = AppModel(client: MockSvodClient.offline)
    app.connection = .disconnected
    return EngineStatusView(model: app.engine)
        .environmentObject(app)
}

#Preview("Engine — error") {
    let app = AppModel(client: MockSvodClient.preview)
    app.connection = .error("Engine did not become ready in time.")
    app.engine.startError = "Timed out waiting for the engine. Check the launchd agent."
    return EngineStatusView(model: app.engine)
        .environmentObject(app)
}
