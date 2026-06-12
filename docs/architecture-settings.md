# Settings — Architecture (Plan)

## Components

### SettingsStore (`Svod/App/SettingsStore.swift`) — new, foundation-level
`@MainActor final class SettingsStore: ObservableObject`, backed by `@AppStorage`
(UserDefaults). Single source of every UI preference. Grouped:
- Connection: `endpointHost` (String, "127.0.0.1"), `endpointPort` (Int, 7517),
  `autoStartEngine` (Bool, true), `autoReconnect` (Bool, true).
- Appearance: `themeMode` (enum system/light/dark, default dark), `readingMeasure`
  (Double), `editorFontSize` (Double), `density` (enum).
- Editor: `autosave` (Bool), `autosaveDebounceMs` (Int), `focusByDefault` (Bool),
  `frontmatterTemplate` (String), `wikilinkAutocomplete` (Bool).
- Search: `defaultMode` (SearchMode), `resultLimit` (Int), `rememberQuery` (Bool).
- Activity: `showAgentActivity/showCommits/showFileChanges/showConflicts` (Bool),
  `feedCap` (Int), `feedAnimation` (Bool).
- Graph: `defaultScope` (GraphModel.Scope), `physicsIntensity` (Double).
- Startup: `reopenLastNote` (Bool), `lastOpenedPath` (String?), `defaultCenterMode`.
Exposes `var baseURL: URL` derived from host/port. Owned by `AppModel`
(`app.settings`), injected as `@EnvironmentObject`.

### Settings scene (`Svod/Features/Settings/`) — new feature folder
- `SettingsScene` content: a `TabView(.sidebar?)` or `NavigationSplitView` list of
  sections → panel views. Native macOS Settings look (⌘, via `Settings { }` scene).
- Panels (one file each): `ConnectionSettings`, `EngineSettings` (lifecycle + info +
  sync status read), `AppearanceSettings`, `EditorSettings`, `SearchSettings`,
  `ActivitySettings`, `GraphSettings`, `SyncBackupSettings` (v2), `AboutSettings`.
- All use DesignSystem tokens + shared form rows.

## Wiring seams (touch frozen App files — lead-owned now)
1. **Theme** — `SvodApp`: replace `.preferredColorScheme(.dark)` with
   `app.settings.themeMode.colorScheme` (nil = system). Add `Settings { SettingsScene() }`
   scene → ⌘, .
2. **Endpoint / client swap** — `AppModel`: client becomes reassignable. Add
   `func reconnect(to: URL)` that builds a new `LiveSvodClient(baseURL:)`, replaces the
   stored client (sub-models read `app.client` → make them read through `app`), and
   re-runs `engine.startConnecting()`. Simplest: `AppModel.client` stays, add
   `applyEndpoint()` that recreates `engine`'s view of the URL. NB: sub-models hold
   their own `client` ref → for v1, recreate the client at app level and have
   EngineModel use `app.client`; document that endpoint change does a full reconnect.
3. **Lifecycle stop** — `EngineModel`: add `stop()` = `launchctl bootout gui/<uid>/<label>`;
   `restart()` = kickstart -k. (start already exists.)
4. **Autosave** — `EditorModel`: on `draft` change, if `settings.autosave`, debounce →
   `save()`. EditorModel reads `app.settings`.
5. **Search default** — `SearchModel.mode` initialized from `settings.defaultMode`;
   `limit` from `settings.resultLimit`.
6. **Activity filters** — `ActivityModel.ingest` consults `settings` for type filters +
   `feedCap`.
7. **Graph default** — `GraphModel.scope` from `settings.defaultScope`.
8. **Startup** — `AppModel.bootstrap()` reopens `settings.lastOpenedPath` if enabled;
   `open(path:)` records it.

Sub-models get `app.settings` via their existing `weak var app`. No new cross-file
contracts beyond `SettingsStore` + `EngineModel.stop()/restart()`.

## v2 — Sync/Backup (engine-gated)
Delegated to the svod engine (harbormaster job `d_be396c6e45f4`). Once the contract
lands, extend in `Networking/`:
- DTOs for read-remotes (settings/sync config), `BackupConfig`, action acks.
- `SvodClient` methods: `syncConfig()`, `setBackup(...)`, `reindex()`, `backupNow()`,
  `syncNow()`. `LiveSvodClient` maps them; **501 → a typed `.notImplemented` that the
  UI renders as "needs engine support"**. `MockSvodClient` returns canned config.
- `SyncBackupSettings` panel: read-only status (from v1 sync read) + (when supported)
  editable backup remote + "Back up now" / "Reindex" actions. Secrets are entered as
  `keychain:`/`env:` references only — never raw.

## Files
New: `Svod/App/SettingsStore.swift`, `Svod/Features/Settings/*` (~9 panels + scene +
shared rows). Edited (frozen, lead-owned): `SvodApp.swift`, `AppModel.swift`,
`EngineModel.swift`, `EditorModel.swift`, `SearchModel.swift`, `ActivityModel.swift`,
`GraphModel.swift`. Networking extended for v2.

## Non-goals
No multi-machine connect (loopback). No raw secret storage. No shortcut rebinding v1.
