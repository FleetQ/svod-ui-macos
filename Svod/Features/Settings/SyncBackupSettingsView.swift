import SwiftUI

// Sync & Backup. Read-only sync status comes from metrics. Backup config + the
// maintenance actions hit engine v0.4.0 endpoints (delegated to the svod engine);
// when the engine returns 501 the controls degrade to a "needs engine support"
// note rather than erroring.

struct SyncBackupSettingsView: View {
    @EnvironmentObject var app: AppModel

    @State private var config: SyncConfig?
    @State private var configUnavailable = false
    @State private var backupRemote = ""
    @State private var backupEnabled = false
    @State private var status: String?
    @State private var busy = false

    private var client: SvodClient { app.client }

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

            Section("Backup remote") {
                if configUnavailable {
                    Label("Configuring backup needs engine support (v0.4.0).", systemImage: "lock")
                        .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                } else {
                    TextField("Git remote (URL; secrets as keychain:/env: refs only)", text: $backupRemote)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Backup enabled", isOn: $backupEnabled)
                    Button("Save backup config") { Task { await saveBackup() } }
                        .disabled(busy || backupRemote.isEmpty)
                }
            }

            Section("Actions") {
                HStack(spacing: Spacing.sm) {
                    Button("Reindex") { Task { await run { try await client.reindex(vault: nil).started ? "Reindex started" : "Reindex queued" } } }
                    Button("Back up now") { Task { await run { let a = try await client.backupNow(vault: nil); return a.ok ? "Backed up\(a.head.map { " · \($0.prefix(8))" } ?? "")" : "Backup failed" } } }
                    Button("Sync now") { Task { await run { let a = try await client.syncNow(vault: nil); return a.ok ? "Synced" : "Sync failed" } } }
                    if busy { ProgressView().controlSize(.small) }
                }
                if let status {
                    Text(status).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                }
            }

            Section {
                Text("The App API stays loopback-only. Backup/sync auth is handled engine-side via Secrets references — never raw secrets over the API.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task {
            await app.engine.loadMeta()
            await loadConfig()
        }
    }

    private func loadConfig() async {
        do {
            let c = try await client.syncConfig(vault: nil)
            config = c
            backupRemote = c.backupRemote ?? ""
            backupEnabled = c.backupEnabled
            configUnavailable = false
        } catch let e as SvodClientError where e.isNotImplemented {
            configUnavailable = true
        } catch {
            configUnavailable = true
        }
    }

    private func saveBackup() async {
        await run {
            let c = try await client.setBackup(vault: nil, remote: backupRemote, enabled: backupEnabled)
            config = c
            return "Backup config saved"
        }
    }

    /// Run an engine action, mapping 501 to a calm "needs engine support" note.
    private func run(_ action: @escaping () async throws -> String) async {
        busy = true; defer { busy = false }
        do { status = try await action() }
        catch let e as SvodClientError where e.isNotImplemented { status = e.errorDescription }
        catch let e as SvodClientError { status = e.errorDescription }
        catch { status = error.localizedDescription }
    }
}

#Preview {
    SyncBackupSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 560, height: 520)
}
