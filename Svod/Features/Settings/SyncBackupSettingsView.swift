import SwiftUI
import AppKit

// Sync & Backup. Sync status is read-only (from metrics). The easy path is
// "Connect GitHub" (OAuth device flow → private repo → Keychain ref). A manual
// remote (keychain:/env:/file: ref) stays available under Advanced. All config +
// actions are per the active vault; on an engine that predates these endpoints
// they degrade to a calm "needs engine support" note.

struct SyncBackupSettingsView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var gh = GitHubBackup()

    @State private var config: SyncConfig?
    @State private var configUnavailable = false
    @State private var backupRemote = ""
    @State private var backupEnabled = false
    @State private var showAdvanced = false
    @State private var status: String?
    @State private var busy = false

    private var client: SvodClient { app.client }
    private var vaultID: String? { app.vault.activeVaultId }

    var body: some View {
        Form {
            Section("Backup") {
                if configUnavailable {
                    Label("Backup needs a newer engine (v1.0+).", systemImage: "lock")
                        .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                } else {
                    githubFlow
                }
            }

            if !configUnavailable {
                Section("Actions") {
                    HStack(spacing: Spacing.sm) {
                        Button("Reindex") { Task { await run { try await client.reindex(vault: vaultID).started ? "Reindex started" : "Reindex queued" } } }
                        Button("Back up now") { Task { await run { let a = try await client.backupNow(vault: vaultID); return a.ok ? "Backed up\(a.head.map { " · \($0.prefix(8))" } ?? "")" : "Backup failed" } } }
                            .disabled((config?.backupRemote ?? "").isEmpty)
                        Button("Sync now") { Task { await run { let a = try await client.syncNow(vault: vaultID); return a.ok ? "Synced" : "Sync failed" } } }
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let status {
                        Text(status).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                    }
                }

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

                Section {
                    DisclosureGroup("Advanced — manual remote", isExpanded: $showAdvanced) {
                        TextField("Git remote (URL or keychain:/env:/file: ref — never a raw secret)", text: $backupRemote)
                            .textFieldStyle(.roundedBorder)
                        Toggle("Backup enabled", isOn: $backupEnabled)
                        Button("Save backup config") { Task { await saveBackup() } }
                            .disabled(busy || backupRemote.isEmpty)
                    }
                }
            }

            Section {
                Text("The App API stays loopback-only. The GitHub token is stored in your Keychain; the engine receives only a `keychain:` reference — never a raw secret over the API.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task {
            await app.engine.loadMeta()
            await loadConfig()
        }
    }

    // MARK: GitHub one-click flow
    @ViewBuilder private var githubFlow: some View {
        switch gh.phase {
        case .idle:
            if let remote = config?.backupRemote, !remote.isEmpty {
                Label("Backing up to \(friendly(remote))", systemImage: "checkmark.seal.fill")
                    .font(Typography.callout).foregroundStyle(ThemeColor.sync)
                Button("Reconnect / change account") { Task { await connectGitHub() } }
            } else {
                Text("Back up this vault to a private GitHub repository.")
                    .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                Button { Task { await connectGitHub() } } label: {
                    Label("Connect GitHub", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(SvodButtonStyle(.primary))
            }
        case .requesting:
            HStack(spacing: Spacing.sm) { ProgressView().controlSize(.small); Text("Contacting GitHub…") }
        case let .awaitingAuth(code, uri):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Authorize Svod in your browser:").font(Typography.callout)
                HStack(spacing: Spacing.sm) {
                    Text(code)
                        .font(Typography.code).textSelection(.enabled)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
                        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.sm))
                    Button { copy(code) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("Copy code")
                    Button("Open GitHub") { open(uri) }
                }
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for authorization…").font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                }
            }
        case .finishing:
            HStack(spacing: Spacing.sm) { ProgressView().controlSize(.small); Text("Setting up your backup repository…") }
        case let .connected(repo):
            Label("Connected — backing up to \(repo)", systemImage: "checkmark.seal.fill")
                .font(Typography.callout).foregroundStyle(ThemeColor.sync)
        case let .failed(msg):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(ThemeColor.danger)
                Button("Try again") { gh.reset() }
            }
        }
    }

    private func connectGitHub() async {
        let vid = vaultID ?? "default"
        guard let result = await gh.connect(vaultId: vid) else { return }
        // Persist the keychain ref + enabled in the engine (raw token never sent).
        backupRemote = result.ref
        backupEnabled = true
        do {
            config = try await client.setBackup(vault: vaultID, remote: result.ref, enabled: true)
            status = "Backup connected. Use “Back up now” to push the first snapshot."
        } catch let e as SvodClientError {
            status = e.errorDescription
        } catch {
            status = error.localizedDescription
        }
    }

    /// Show a calm label for a ref without leaking anything (refs carry no secret).
    private func friendly(_ remote: String) -> String {
        if remote.hasPrefix("keychain:") { return "a private GitHub repo (Keychain)" }
        return remote
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
    private func open(_ uri: String) { if let u = URL(string: uri) { NSWorkspace.shared.open(u) } }

    private func loadConfig() async {
        do {
            let c = try await client.syncConfig(vault: vaultID)
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
            let c = try await client.setBackup(vault: vaultID, remote: backupRemote, enabled: backupEnabled)
            config = c
            return "Backup config saved"
        }
    }

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
        .frame(width: 560, height: 560)
}
