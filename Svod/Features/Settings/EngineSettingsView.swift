import SwiftUI

struct EngineSettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Lifecycle") {
                LabeledContent("Status") {
                    StatusPill(app.connection.label, tone: app.connection.pillTone)
                }
                HStack(spacing: Spacing.sm) {
                    Button("Start") { Task { await app.engine.start() } }
                        .disabled(app.connection == .connected || app.connection == .starting)
                    Button("Restart") { Task { await app.engine.restart() } }
                    Button("Stop", role: .destructive) { app.engine.stop() }
                        .disabled(app.connection == .disconnected)
                }
                if let err = app.engine.startError {
                    Text(err).font(Typography.caption).foregroundStyle(ThemeColor.danger)
                }
            }

            if let s = app.engine.settings {
                Section("Vault & engine") {
                    LabeledContent("Vault path", value: s.vaultPath)
                    LabeledContent("API version", value: s.apiVersion)
                    LabeledContent("Host", value: s.host)
                    LabeledContent("Embedder", value: "\(s.embedderProvider)\(s.embedderModel.map { " · \($0)" } ?? "")")
                    if let dim = s.embedderDim { LabeledContent("Dimensions", value: String(dim)) }
                }
            }

            if let i = app.engine.indexStatus {
                Section("Index") {
                    LabeledContent("Documents", value: String(i.docCount))
                    LabeledContent("Model", value: "\(i.model) (\(i.dim))")
                    if let head = i.headIndexed { LabeledContent("Indexed head", value: String(head.prefix(8))) }
                }
            }

            if let m = app.engine.metrics {
                Section("Write metrics") {
                    LabeledContent("Writes", value: String(m.write.count))
                    LabeledContent("Avg / Max", value: String(format: "%.1f ms / %.1f ms", m.write.avgMs, m.write.maxMs))
                    LabeledContent("Queue depth", value: "\(m.queueDepth) (peak \(m.peakQueueDepth))")
                }
            }
        }
        .formStyle(.grouped)
        .task { await app.engine.loadMeta() }
    }
}

#Preview {
    let app = AppModel(client: MockSvodClient.preview)
    return EngineSettingsView()
        .environmentObject(app)
        .frame(width: 560, height: 520)
        .task { await app.engine.loadMeta() }
}
