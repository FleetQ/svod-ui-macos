# Retro — Settings sprint (2026-06-12)

## Shipped (branch `feat/settings`, not merged/pushed)
- **v1 (complete, working against the live engine):** SettingsStore + ⌘, scene with
  9 panels (Connection, Engine, Sync&Backup, Appearance, Editor, Search, Activity,
  Graph, About). Wired into real behavior: live theme switch, endpoint swap +
  reconnect, engine start/restart/stop, debounced autosave, search defaults,
  activity feed filters/cap, graph default scope, reopen-last-note.
- **v2 UI (complete, graceful):** adopted engine v0.3.0 conflict shape
  (base/ours/theirs/ts) + `POST /conflicts/resolve`; added sync/backup client
  methods (`syncConfig/setBackup/reindex/backupNow/syncNow`, per-vault `?vault=`);
  `SvodClientError.notImplemented` so unsupported features degrade to "needs engine
  support" instead of erroring. SyncBackup panel drives the real actions.
- **Engine v2 endpoints:** delegated to the svod engine agent (harbormaster).

## Metrics
- 2 commits, 28 files (+1339/−7), 18 new files. Build green throughout; live smoke
  passed (connects, Settings renders, DTOs decode against live v0.3.0).

## What went well
- Frozen-contract foundation paid off again: settings threaded through `app.settings`
  + sub-model back-refs with no churn to feature views.
- Endpoint switching solved cleanly by making the *shared* `LiveSvodClient.baseURL`
  mutable — one change redirects every sub-model.
- The engine agent's caution was the highlight: it **refused to commit** into another
  agent's uncommitted multivault work, and surfaced that the conflict 3-way + per-vault
  sync had already shipped/were in flight. That intel reshaped v2 correctly.

## What was bumpy
- `Settings` DTO name shadowed SwiftUI's `Settings` scene → qualified as `SwiftUI.Settings`.
- Local init helpers captured `self` before init completed → switched to a local
  `UserDefaults`.
- v2 engine work is **blocked by an in-flight multivault refactor** in the engine repo;
  resolved by re-delegating into an isolated worktree (`feat/ui-settings-endpoints`).

## Action items / follow-ups
1. **Engine merge decision (user):** the multivault feature and the UI-settings
   endpoints are two branches in `~/htdocs/svod`. Decide merge order; the UI's v2
   client methods already assume the per-vault `?vault=` convention.
2. When the engine `feat/ui-settings-endpoints` branch lands + deploys, re-validate the
   v2 DTOs against live and flip SyncBackup from 404/501 fallback to real data.
3. Consider wiring `/conflicts/resolve` (now real) into the History conflict flow as an
   alternative to the write-back path.
4. Decide whether to surface `GET /api/v1/vaults` as a vault switcher (the "multiple
   local vaults" idea), now that the engine supports it.
