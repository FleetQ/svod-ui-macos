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
    @State private var busyLabel: String?
    @State private var elapsed = 0
    @State private var repoName = ""
    // Auto-backup schedule mirrors (loaded from the engine config; edits write back).
    @State private var autoInterval = 0       // minutes; 0 = off
    @State private var autoOnChange = false
    @State private var autoOnStartup = false
    @State private var scheduleLoaded = false  // guards onChange→save during initial load
    // Two-way multi-machine sync (contract 0.12.0). Reuses the backup remote as the bus.
    @State private var syncOn = false
    @State private var syncInterval = 0        // minutes; 0 = engine default (3)

    /// Last successful backup, parsed from the engine's ISO-8601 marker.
    private var lastBackupText: String? {
        guard let iso = config?.lastBackupAt else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { "Last backup \($0.formatted(.relative(presentation: .named)))" }
    }

    /// Human label for the live sync state (from metrics; falls back to the config role).
    private var syncStateText: String {
        switch app.engine.metrics?.sync?.syncStatus ?? config?.role ?? "synced" {
        case "inSync":    return "In sync"
        case "syncing":   return "Syncing…"
        case "conflicts": return "Conflicts to resolve"
        case "offline":   return "Offline"
        case "error":     return "Error"
        case let other:   return other.prefix(1).uppercased() + other.dropFirst()
        }
    }

    private var lastSyncedText: String? {
        guard let iso = app.engine.metrics?.sync?.lastSyncedAt else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { $0.formatted(.relative(presentation: .named)) }
    }

    /// Off-site freshness for the header. Once two-way sync is on, sync IS the off-site copy, so
    /// report the last successful sync — the engine intentionally freezes the one-way backup marker
    /// (`lastBackupAt`) while sync is on, and showing it reads as a stale "backed up weeks ago".
    private var offsiteFreshnessText: String? {
        if config?.syncEnabled == true { return lastSyncedText.map { "Synced \($0)" } }
        return lastBackupText
    }

    private var progressText: String {
        let t = elapsed > 0 ? " · \(elapsed)s" : ""
        let hint = elapsed >= 6 ? " — large vaults or the first push can take a while" : ""
        return (busyLabel ?? "Working") + "…" + t + hint
    }

    /// Two-way sync is available to run once it's been enabled for this vault.
    private var syncUnavailable: Bool { !(config?.syncEnabled ?? false) }

    /// Single writer for the backup endpoint — both the schedule and the sync toggle
    /// flow through here so neither clobbers the other's fields.
    private func persistBackup(message: String) async {
        guard scheduleLoaded, let remote = config?.backupRemote, !remote.isEmpty else { return }
        await run("Saving") {
            let c = try await client.setBackup(vault: vaultID, remote: remote,
                                               enabled: config?.backupEnabled ?? true,
                                               backupOnStartup: autoOnStartup,
                                               backupIntervalMinutes: autoInterval,
                                               backupOnChange: autoOnChange,
                                               syncEnabled: syncOn,
                                               syncIntervalMinutes: syncOn ? (syncInterval == 0 ? nil : syncInterval) : nil)
            config = c
            return message
        }
    }

    private func saveSchedule() async {
        await persistBackup(message: (autoInterval == 0 && !autoOnChange && !autoOnStartup)
                            ? "Automatic backup off" : "Automatic backup updated")
    }

    private func saveSync() async {
        await persistBackup(message: syncOn
                            ? "Two-way sync on — this vault now reconciles across your machines"
                            : "Two-way sync off")
    }

    private func syncMessage(_ a: SyncAck) -> String {
        let n = a.conflicts ?? 0
        if a.ok { return n > 0 ? "Synced · \(n) conflict\(n == 1 ? "" : "s")" : "Synced" }
        return n > 0 ? "Sync left \(n) conflict\(n == 1 ? "" : "s")" : "Two-way sync isn’t on for this vault."
    }

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
                if (config?.backupRemote ?? "").isEmpty == false {
                    Section("Automatic backup") {
                        Picker("Schedule", selection: $autoInterval) {
                            Text("Off (manual only)").tag(0)
                            Text("Every 15 minutes").tag(15)
                            Text("Every 30 minutes").tag(30)
                            Text("Hourly").tag(60)
                            Text("Every 6 hours").tag(360)
                            Text("Daily").tag(1440)
                        }
                        .onChange(of: autoInterval) { _, _ in Task { await saveSchedule() } }
                        Toggle("Back up after edits settle", isOn: $autoOnChange)
                            .onChange(of: autoOnChange) { _, _ in Task { await saveSchedule() } }
                        Toggle("Back up on engine startup", isOn: $autoOnStartup)
                            .onChange(of: autoOnStartup) { _, _ in Task { await saveSchedule() } }
                        Text("Runs in the background, pushing to the same private repo. Engine v1.3+.")
                            .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(busy || syncOn)

                    Section("Sync across your machines") {
                        Toggle("Keep this vault in sync on all my Macs", isOn: $syncOn)
                            .onChange(of: syncOn) { _, _ in Task { await saveSync() } }
                        if syncOn {
                            Picker("Check for changes", selection: $syncInterval) {
                                Text("Default (every 3 minutes)").tag(0)
                                Text("Every 5 minutes").tag(5)
                                Text("Every 15 minutes").tag(15)
                                Text("Every 30 minutes").tag(30)
                                Text("Hourly").tag(60)
                            }
                            .onChange(of: syncInterval) { _, _ in Task { await saveSync() } }
                        }
                        Text(syncOn
                             ? "The same private repo is now a two-way bus. Each Mac fetches, merges, and pushes on this cadence; non-overlapping edits merge silently, real overlaps land in the conflict list. One-way backup is retired while sync is on."
                             : "Turns the backup repo into a two-way bus so edits flow between your machines automatically. Replaces one-way backup. Engine v1.4+.")
                            .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if syncOn {
                            Text("Add another Mac: install Svod there and run `svod-engine clone <repo-url> ~/Svod/\(vaultID ?? "default") \(vaultID ?? "default")` before first launch, then enable sync on it too.")
                                .font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(busy)
                }

                Section("Actions") {
                    HStack(spacing: Spacing.sm) {
                        Button("Reindex") { Task { await run("Reindexing") { try await client.reindex(vault: vaultID).started ? "Reindex started" : "Reindex queued" } } }
                        Button("Back up now") { Task { await run("Backing up") {
                            let priorHead = config?.lastBackupHead
                            let a = try await client.backupNow(vault: vaultID)
                            if a.ok { await loadConfig() }   // refresh last-backup marker from the engine
                            if a.ok { return "Backed up\(a.head.map { " · \($0.prefix(8))" } ?? "")" }
                            // Engine reports ok:false with the current head when the push was a
                            // no-op ("Everything up-to-date") — nothing changed since the last
                            // backup. That's not a failure, so don't alarm the user.
                            if let h = a.head, h == priorHead { return "Already up to date · \(h.prefix(8))" }
                            return "Backup failed"
                        } } }
                            .disabled((config?.backupRemote ?? "").isEmpty)
                        Button("Sync now") { Task { await run("Syncing") {
                            let a = try await client.syncNow(vault: vaultID)
                            await loadConfig()
                            return syncMessage(a)
                        } } }
                            .disabled(syncUnavailable)
                            .help(syncUnavailable
                                  ? "Turn on “Keep this vault in sync” above first. Until then this vault only backs up one-way."
                                  : "Fetch, merge, and push changes with your other Macs now.")
                    }
                    .disabled(busy)
                    if busy {
                        HStack(spacing: Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text(progressText).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                        }
                    } else if let status {
                        Text(status).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                    }
                }

                Section("Sync status") {
                    if config?.syncEnabled == true {
                        LabeledContent("State", value: syncStateText)
                        if let at = lastSyncedText { LabeledContent("Last sync", value: at) }
                        if let sync = app.engine.metrics?.sync {
                            LabeledContent("Conflicts", value: String(sync.conflicts))
                        }
                        if let host = config?.hostId { LabeledContent("This Mac", value: host) }
                    } else {
                        Text("Two-way sync is off for this vault.")
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
                Text("The App API stays loopback-only. The GitHub token is written to a user-only local file (chmod 600); the engine receives only a `file:` reference — never a raw secret over the API.")
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
                Label(config?.syncEnabled == true ? "Syncing to \(friendly(remote))" : "Backing up to \(friendly(remote))",
                      systemImage: "checkmark.seal.fill")
                    .font(Typography.callout).foregroundStyle(ThemeColor.sync)
                Text(offsiteFreshnessText ?? (config?.syncEnabled == true
                     ? "Not synced yet — press “Sync now” or wait for the next cycle."
                     : "Not backed up yet — press “Back up now” or turn on automatic backup below."))
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(config?.syncEnabled == true
                     ? "This vault is pushed off-site continuously by sync (git ref refs/svod/sync/\(vaultID ?? "default")). One-way backup is retired while sync is on, so its own “last backup” time no longer advances. GitHub’s web view lists only branches/tags — verify with `git ls-remote`."
                     : "Snapshots are pushed to a git ref (refs/svod/backup/\(vaultID ?? "default")) — safe and restorable, but GitHub’s web view won’t list them (it shows only branches/tags). Verify with `git ls-remote`.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reconnect / change account") { Task { await connectGitHub() } }
            } else {
                Text("Back up this vault to a private GitHub repository.")
                    .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                TextField("Repository name", text: $repoName,
                          prompt: Text("svod-backup-\(vaultID ?? "default")"))
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank for the default. A private repo with this name is created (or reused) under your account.")
                    .font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
        guard let result = await gh.connect(vaultId: vid, repoName: repoName) else { return }
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

    /// Show a calm label for a ref without leaking anything. Refs (file:/keychain:/env:)
    /// carry no secret; a raw URL is mask-stripped of any embedded credentials before display.
    private func friendly(_ remote: String) -> String {
        if remote.hasPrefix("file:") || remote.hasPrefix("keychain:") || remote.hasPrefix("env:") {
            return "a private GitHub repo"
        }
        return Self.maskRemote(remote)
    }

    /// Strip any embedded `user[:password]@` credentials from a URL so a token set
    /// outside this app (CLI / older version / synced peer) is never shown on screen.
    static func maskRemote(_ remote: String) -> String {
        guard let c = URLComponents(string: remote), (c.user != nil || c.password != nil),
              let host = c.host else { return remote }
        let scheme = c.scheme.map { "\($0)://" } ?? ""
        return "\(scheme)***@\(host)\(c.path)"
    }

    /// A remote safe to seed into the editable Advanced field: refs pass through, but a
    /// raw credential URL is withheld so the token never lands in an on-screen text field.
    static func safeEditableRemote(_ remote: String) -> String {
        if remote.hasPrefix("file:") || remote.hasPrefix("keychain:") || remote.hasPrefix("env:") { return remote }
        if let c = URLComponents(string: remote), c.user != nil || c.password != nil { return "" }
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
            backupRemote = Self.safeEditableRemote(c.backupRemote ?? "")
            backupEnabled = c.backupEnabled
            scheduleLoaded = false                 // suppress onChange→save while seeding
            autoInterval = c.backupIntervalMinutes ?? 0
            autoOnChange = c.backupOnChange
            autoOnStartup = c.backupOnStartup
            syncOn = c.syncEnabled
            syncInterval = c.syncIntervalMinutes ?? 0
            scheduleLoaded = true
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

    private func run(_ label: String? = nil, _ action: @escaping () async throws -> String) async {
        busy = true; busyLabel = label; elapsed = 0; status = nil
        // Tick an elapsed-seconds counter so a long git op (backup/sync) shows it's alive.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                elapsed += 1
            }
        }
        defer { ticker.cancel(); busy = false; busyLabel = nil }
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
