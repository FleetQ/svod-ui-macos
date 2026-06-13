# Svod UI — Settings feature (v1 + v2) & engine delegation

Sprint 2026-06-12 via `/sprint-orchestrate full`. Builds on `mem:svod-ui-architecture`. All work on branch **`feat/settings`** (NOT merged/pushed). Docs: `docs/{settings-requirements,design-settings,architecture-settings,test-plan-settings}.md`, retro `retro/retro-2026-06-12-settings.md`.

## SettingsStore (`Svod/App/SettingsStore.swift`)
`@MainActor ObservableObject`, UserDefaults-backed (keys prefixed `svod.settings.`), didSet-persist + init-load (no @AppStorage in the class — didSet doesn't fire in init, so init reads UserDefaults directly via a LOCAL `let ud`, NOT `self.d`, or you get "self used before init"). Owned by `AppModel.settings`. Groups: Connection (endpointHost/Port, autoStart/autoReconnect), Appearance (themeMode system/light/dark, readingMeasure, editorFontSize, density), Editor (autosave+debounceMs, focusByDefault, wikilinkAutocomplete, frontmatterTemplate), Search (defaultSearchMode, searchResultLimit, rememberQuery), Activity (4 type toggles, feedCap, feedAnimation), Graph (defaultGraphScopeLocal, physicsIntensity), Startup (reopenLastNote, lastOpenedPath). `baseURL` derived from host:port. `showsEvent(_:)`, `validate(host:port:)`.

## Settings scene (`Svod/Features/Settings/`)
⌘, via `SwiftUI.Settings { SettingsScene() }` in SvodApp — **MUST qualify `SwiftUI.Settings`** because our DTO `Settings` shadows the scene. NavigationSplitView sidebar (9 sections) → panels: Connection, Engine, SyncBackup, Appearance, Editor, Search, Activity, Graph, About. Panels take `@ObservedObject var settings: SettingsStore` (passed `app.settings`, so `$settings.x` bindings work) + `@EnvironmentObject app` where needed. Native `Form{}.formStyle(.grouped)`.

## Wiring seams (lead edited frozen App files)
- Theme: SvodApp `.preferredColorScheme(app.settings.themeMode.colorScheme)`; AppModel forwards `settings.objectWillChange` → its own, so the App body re-themes live.
- **Endpoint swap**: `LiveSvodClient.baseURL` is now `private(set) var` + `updateBaseURL(_:)`. All sub-models share ONE client instance, so mutating its baseURL redirects everyone. `AppModel.applyEndpoint()` → updateBaseURL + `engine.reconnectNow()`.
- Lifecycle: `EngineModel.stop()` (launchctl bootout), `restart()`, `reconnectNow()`. autoReconnect gates `handleDisconnect`.
- Autosave: `EditorModel.draft` didSet → debounced `save()`, guarded by `suppressAutosave` during load (else load→didSet→save loop).
- SearchModel uses `app.settings.searchResultLimit`; ActivityModel.ingest honors type filters + feedCap + feedAnimation; AppModel seeds search.mode/graph.scope from settings post-init; bootstrap reopens lastOpenedPath.
- Toolbar: `SettingsLink { Image(systemName:"gearshape") }` gear opens Settings. `closeOnEsc()` modifier (hidden `.cancelAction` button → `NSApp.keyWindow?.performClose`) on SettingsScene; conflict sheet dismisses on Esc too. Main window intentionally NOT Esc-closable.

## v2 — sync/backup (engine-gated, graceful)
Added DTOs + `SvodClient` methods: `resolveConflict`, `syncConfig/setBackup/reindex/backupNow/syncNow` (per-vault `?vault=`). New `SvodClientError.notImplemented` (501) + `isNotImplemented`; LiveSvodClient maps 501. Mock returns canned config/acks, `syncNow` throws notImplemented. `SyncBackupSettingsView` drives real actions, degrades to "needs engine support" on 501/404.

## Engine contract moved (IMPORTANT — supersedes the gap noted in mem:svod-ui-architecture)
Engine is now **v0.3.0**: `GET /conflicts` items now carry **base/ours/theirs/ts** and `POST /api/v1/conflicts/resolve` { path, content, expectedRevision? } → WriteResult exists — the 3-way merge gap is CLOSED. Also `GET /api/v1/vaults` → per-vault model; sync is becoming per-vault (`VaultSettings.syncRemotes/mergeAuthority`). `/settings` still has no sync/backup fields.

## Engine v2 delegation (harbormaster → `svod` project, ~/htdocs/svod)
- The v2 endpoints (sync/config, PUT settings/backup, maintenance/reindex, backup/now, sync/now; target v0.4.0) were delegated. The engine agent **correctly refused to commit** into a **parallel in-flight multivault feature** (uncommitted, same files).
- Re-delegated to build in an ISOLATED worktree `../svod-wt-ui-endpoints` branch `feat/ui-settings-endpoints` off `1ce5878`. Job id `d_38b0c4cc0218`, inbox `svod-ui-settings` — recall via `recall_pending_results(inbox_id='svod-ui-settings')`. Was still RUNNING at sprint end.
- OPEN: operator must decide engine merge order (multivault vs ui-settings-endpoints) and redeploy before the UI's v2 reads live data.
