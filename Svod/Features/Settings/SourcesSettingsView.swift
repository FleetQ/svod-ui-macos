import SwiftUI
import AppKit

// Sources — re-syncable external files/dirs (engine v0.6.0). Register a folder/file
// from outside the vault, then sync it in; re-syncing is external-wins-unless-
// locally-edited (a vault copy you edited is reported as a conflict, never clobbered).
// Per the active vault. Degrades to a calm note on engines without /sources.

struct SourcesSettingsView: View {
    @EnvironmentObject var app: AppModel

    @State private var sources: [ExternalSource] = []
    @State private var results: [String: SourceSyncResult] = [:]   // id → last sync result
    @State private var addFollowSymlinks = false
    @State private var addPrune = false
    @State private var addAutoSync = false
    @State private var unavailable = false
    @State private var busy = false
    @State private var status: String?

    private var client: SvodClient { app.client }
    private var vaultID: String? { app.vault.activeVaultId }

    var body: some View {
        Form {
            if unavailable {
                Section {
                    Label("External sources need a newer engine (v0.6+).", systemImage: "lock")
                        .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                }
            } else {
                Section("External sources") {
                    if sources.isEmpty {
                        Text("Sync documents and whole directories from other places into this vault. Re-syncing keeps them current — external wins unless you’ve edited the vault copy.")
                            .font(Typography.callout).foregroundStyle(ThemeColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(sources) { sourceRow($0) }
                }

                Section("Add a source") {
                    Toggle("Follow symlinks inside the folder", isOn: $addFollowSymlinks)
                    Toggle("Propagate deletions (prune)", isOn: $addPrune)
                    Toggle("Auto-sync on change (watch the folder)", isOn: $addAutoSync)
                    Button { pickAndAdd() } label: { Label("Add folder or file…", systemImage: "plus") }
                        .disabled(busy)
                }

                if !sources.isEmpty {
                    Section {
                        HStack(spacing: Spacing.sm) {
                            Button { Task { await syncAll() } } label: {
                                Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                            }.disabled(busy)
                            if busy { ProgressView().controlSize(.small) }
                        }
                        if let status {
                            Text(status).font(Typography.caption).foregroundStyle(ThemeColor.textSecondary)
                        }
                    }
                }
            }

            Section {
                Text("Sources pull documents from outside the vault (e.g. a project’s docs) and re-sync them. A vault copy you’ve edited is never overwritten — it’s reported as a conflict.")
                    .font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .task { await load() }
        .task(id: app.reloadEpoch) { guard app.reloadEpoch > 0 else { return }; await load() }
    }

    // MARK: row
    @ViewBuilder private func sourceRow(_ s: ExternalSource) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "externaldrive").foregroundStyle(ThemeColor.textTertiary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.name).font(Typography.callout).foregroundStyle(ThemeColor.textPrimary)
                    Text(s.path).font(Typography.caption).foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Spacing.sm)
                Button("Sync") { Task { await sync(s) } }.disabled(busy)
                Button(role: .destructive) { Task { await remove(s) } } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.plain).help("Remove source (synced files stay)")
            }
            HStack(spacing: Spacing.xs) {
                if s.followSymlinks { tag("symlinks") }
                if s.prune { tag("prune") }
                if s.autoSync {
                    Label(s.watching ? "watching" : "watcher off",
                          systemImage: s.watching ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                        .font(Typography.caption2)
                        .foregroundStyle(s.watching ? ThemeColor.sync : ThemeColor.warning)
                }
                Text(lastSynced(s)).font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
            }
            Toggle("Auto-sync on change", isOn: Binding(
                get: { s.autoSync },
                set: { on in Task { await setAutoSync(s, on) } }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(Typography.caption)
                .disabled(busy)
            if let r = results[s.id] { resultSummary(r) }
        }
        .padding(.vertical, Spacing.xxs)
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(Typography.caption2).foregroundStyle(ThemeColor.textSecondary)
            .padding(.horizontal, Spacing.xs).padding(.vertical, 1)
            .background(ThemeColor.surfaceRaised, in: Capsule())
    }

    @ViewBuilder private func resultSummary(_ r: SourceSyncResult) -> some View {
        if let e = r.error {
            Label(e, systemImage: "exclamationmark.triangle").font(Typography.caption2).foregroundStyle(ThemeColor.danger)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.sm) {
                    part("\(r.created.count) new", ThemeColor.sync, r.created.count)
                    part("\(r.updated.count) updated", ThemeColor.accent, r.updated.count)
                    part("\(r.conflicts.count) conflict", ThemeColor.conflict, r.conflicts.count)
                    part("\(r.orphaned.count) orphaned", ThemeColor.textTertiary, r.orphaned.count)
                    part("\(r.deleted.count) deleted", ThemeColor.textTertiary, r.deleted.count)
                    part("\(r.skipped.count) skipped", ThemeColor.conflict, r.skipped.count)
                }
                .font(Typography.caption2)
                // Conflicts need attention — the vault copy was edited locally and left
                // untouched, so surface the exact files (not just a count).
                if !r.conflicts.isEmpty { conflictList(r.conflicts) }
            }
        }
    }

    @ViewBuilder private func conflictList(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Kept your local edits — not overwritten:", systemImage: "exclamationmark.triangle.fill")
                .font(Typography.caption2).foregroundStyle(ThemeColor.conflict)
            ForEach(paths.prefix(8), id: \.self) { p in
                Text(p).font(Typography.caption2).foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if paths.count > 8 {
                Text("+ \(paths.count - 8) more").font(Typography.caption2).foregroundStyle(ThemeColor.textTertiary)
            }
        }
        .padding(Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColor.conflictSubtle, in: RoundedRectangle(cornerRadius: 6))
    }
    @ViewBuilder private func part(_ label: String, _ color: Color, _ n: Int) -> some View {
        if n > 0 { Text(label).foregroundStyle(color) }
    }

    private func lastSynced(_ s: ExternalSource) -> String {
        guard let iso = s.lastSyncedAt else { return "Never synced" }
        return "Last synced " + String(iso.prefix(10))
    }

    // MARK: actions
    private func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Source"
        panel.message = "Choose a folder or file to sync into this vault."
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { await add(path: url.path) }
        }
    }

    private func add(path: String) async {
        await run {
            let s = try await client.registerSource(vault: vaultID, path: path, into: nil,
                                                     followSymlinks: addFollowSymlinks, prune: addPrune,
                                                     autoSync: addAutoSync)
            let r = try await client.syncSource(id: s.id, vault: vaultID)   // register doesn't sync
            results[s.id] = r
            await load()
            app.refreshActiveVault()
            let watch = addAutoSync ? " · watching for changes" : ""
            return "Added “\(s.name)” — \(r.changed) file(s) synced\(watch)"
        }
    }

    private func sync(_ s: ExternalSource) async {
        await run {
            let r = try await client.syncSource(id: s.id, vault: vaultID)
            results[s.id] = r
            app.refreshActiveVault()
            return "Synced “\(s.name)” — \(r.changed) changed\(r.conflicts.isEmpty ? "" : ", \(r.conflicts.count) conflict")"
        }
    }

    private func syncAll() async {
        await run {
            let rs = try await client.syncAllSources(vault: vaultID)
            for r in rs { results[r.id] = r }
            app.refreshActiveVault()
            let changed = rs.reduce(0) { $0 + $1.changed }
            return "Synced \(rs.count) source(s) — \(changed) changed"
        }
    }

    private func setAutoSync(_ s: ExternalSource, _ on: Bool) async {
        guard on != s.autoSync else { return }
        await run {
            _ = try await client.updateSource(id: s.id, vault: vaultID, autoSync: on,
                                              followSymlinks: nil, prune: nil)
            await load()
            return on ? "Watching “\(s.name)” for changes" : "Auto-sync off for “\(s.name)”"
        }
    }

    private func remove(_ s: ExternalSource) async {
        await run {
            try await client.removeSource(id: s.id, vault: vaultID)
            results[s.id] = nil
            await load()
            return "Removed “\(s.name)” (its files stay in the vault)"
        }
    }

    private func load() async {
        do {
            sources = try await client.listSources(vault: vaultID)
            unavailable = false
        } catch let e as SvodClientError where e.isNotImplemented {
            unavailable = true
        } catch let e as SvodClientError where e.isOffline {
            // leave whatever we have; not a hard failure
            _ = e
        } catch {
            unavailable = true
        }
    }

    private func run(_ action: @escaping () async throws -> String) async {
        busy = true; defer { busy = false }
        do { status = try await action() }
        catch let e as SvodClientError { status = e.errorDescription }
        catch { status = error.localizedDescription }
    }
}

#Preview {
    SourcesSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 580, height: 560)
}
