# Svod UI — backup & sync (last updated 2026-06-25)

App API on **127.0.0.1:7619**. Engine companion ~/htdocs/svod. Contract now **0.16.0** (vaults CRUD — POST /vaults, DELETE /vaults/{id}), engine v1.6.4+ from source (gradle run). **:7517 is dead** — old launchd v0.2.0 never replaced; app points to :7619 via `defaults write dev.svod.Svod svod.settings.endpointPort 7619`. See `mem:svod-engine-deploy-gotcha` and `mem:svod-graph-search-editor-fixes`.

## How backup actually works (was confusing)
- `POST /api/v1/backup/now` pushes the vault to a **custom git ref** `refs/svod/backup/<vaultId>` on the remote (intentional — isolates backups, multi-vault-on-one-remote safe; see engine SvodConfig.kt / BackupService.kt).
- **GitHub web UI only shows refs/heads/* + tags**, so the repo looks EMPTY even though the snapshot is there. Verify: `git ls-remote <url>` → line ending `refs/svod/backup/<vault>` = latest snapshot sha.
- The repo's `main` is just the auto_init README. UI writes an informative README on connect (GitHubBackup.writeReadme via GitHub Contents API) explaining the ref layout so nobody deletes the "empty" repo.

## Backup config endpoints
- `GET /api/v1/sync/config` → SyncConfig: `backupRemote, backupEnabled, backupOnStartup, backupIntervalMinutes(Int? null=off), backupOnChange, lastBackupAt(ISO-8601), lastBackupHead, syncPeers, role, hostId, syncEnabled, syncStatus, lastSyncedAt`.
- `PUT /api/v1/settings/backup` (NOT /api/v1/backup — that 404s) body BackupConfigRequest `{remote, enabled, backupOnStartup, backupIntervalMinutes(0=off), backupOnChange}`. Credentials only as Secrets refs (raw → 422).
- Manual backup persists `lastBackupAt`/`lastBackupHead`; auto-backup scheduler (BackupScheduler, contract 0.11.0) does too.

## CRITICAL: Sync disables automatic backup UI (by design)
```swift
Section("Automatic backup") { ... }
    .disabled(busy || syncOn)
```
When `syncEnabled: true`, the entire "Automatic backup" section (schedule picker + toggles) is greyed out. This is **intentional** — two-way sync already pushes on every sync cycle, making a separate backup schedule redundant. Caption in Sync section: *"One-way backup is retired while sync is on."*

**Current state (2026-06-25)**: personal vault has `syncEnabled: true`, `syncStatus: inSync`, `lastSyncedAt` active → backup schedule picker will always appear locked. To re-enable it, turn off "Keep this vault in sync" in Settings.

## UI (SyncBackupSettingsView)
- "Automatic backup" section: Schedule picker (0/15/30/60/360/1440 min) + "back up after edits settle" (backupOnChange) + "back up on engine startup" (backupOnStartup) → `setBackup(...)` on change. Guard `scheduleLoaded` prevents the seed-from-config writes from re-triggering save.
- Connect GitHub: repo-name TextField (default `svod-backup-<vault>`, sanitized in GitHubBackup.sanitizeRepoName); `connect(vaultId:repoName:)`.
- DTOs: SyncConfig + BackupConfigRequest extended with tolerant `init(from:)` (older engines omit fields); `setBackup` has a 3-arg convenience overload (manual/no-schedule).

## Sync vs backup (don't confuse)
- "Sync now" (`POST /api/v1/sync/now`) = multi-host git replication between **peers**. With `role: solo` + `syncPeers: []` it returns `ok:false` — UI disables "Sync now" when `syncPeers.isEmpty`.
- "Reindex" (`POST /api/v1/maintenance/reindex`) = rebuild keyword/BM25 + link/tag index from git HEAD. Different from Indexing→Re-index (`/index/reembed` = embeddings).

## Networking timeouts (LiveSvodClient)
- Base `timeoutIntervalForRequest` 30s + `timeoutIntervalForResource` 600s. Long git ops pass per-request **timeout: 180** via `send`/`sendNoBody`.
- SyncBackupSettingsView `run(label:)` shows live elapsed-seconds spinner during long ops.

## Sidebar auto-refresh (added 2026-06-25, commit a6ecaf8)
When external agents create files, sidebar didn't update. Fix: `SidebarModel.scheduleRefresh()` (500ms debounce) + `SidebarView.onChange(of: app.latestEvent)` reacts to `commitCreated / fileChanged / sourceSynced` WS events. Manual `↺` button in Notes header.
