import SwiftUI

// Sync & Backup. The read-only sync status is available now (metrics.sync).
// Configuring backup/sync remotes + the maintenance actions are engine-gated
// (delegated to the svod engine). Until those endpoints land this panel degrades
// to view-only with a clear note — never a dead control.

struct SyncBackupSettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Sync status") {
                if let sync = app.engine.metrics?.sync {
                    LabeledContent("Role", value: sync.role)
                    if let head = sync.lastHead { LabeledContent("Last head", value: String(head.prefix(8))) }
                    LabeledContent("Conflicts", value: String(sync.conflicts))
                } else {
                    Text("Multi-host sync is not active.")
                        .font(Typography.callout).foregroundStyle(ThemeColor.textTertiary)
                }
            }

            Section("Backup & sync configuration") {
                Label("Configuring backup and sync remotes needs engine support.",
                      systemImage: "lock")
                    .font(Typography.callout)
                    .foregroundStyle(ThemeColor.textSecondary)
                Text("This panel will let you set the backup remote, run “Back up now”, and reindex once the engine exposes those endpoints. The App API stays loopback-only and secrets are entered only as keychain:/env: references.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task { await app.engine.loadMeta() }
    }
}

#Preview {
    SyncBackupSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 560, height: 360)
}
