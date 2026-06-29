# Svod UI — create-vault feature (session 2026-06-22)

Added the ability to CREATE a new vault from the macOS app. Before this, the only vault ops were list (`GET /api/v1/vaults`) and import-into-existing (`POST /api/v1/import`); new vaults required hand-editing the engine config + restart.

## Engine (~/htdocs/svod, committed `bcafa29` on main + PUSHED to origin (FleetQ/svod-engine), contract **0.15.0**, DEPLOYED live to :7619)
- NEW `POST /api/v1/vaults` (operationId `createVault`). Request `CreateVaultRequest{ id (req, slug `^[a-z0-9][a-z0-9_-]*$`), name?, path? }` → **201** Vault row `{id,name,default,sync?}` (same shape as GET /vaults items). Errors: 409 duplicate id OR target dir non-empty; 400 bad id; 422 unwritable path.
- Behavior: mkdir + git init + seed commit; **persists to the engine config file** (survives restart); **hot-adds** to the running engine (lists + `?vault=` routes immediately, no restart); starts sync role solo.
- New files `engine/.../lifecycle/{VaultController,ConfigStore}.kt`. **`ConfigStore`** is now the single shared source of truth for the persistent config — `EmbedderController` was refactored to mutate config via `ConfigStore.update{}` instead of its own `config`+`configPath`, so a vault added concurrently isn't clobbered by an embedder change. `ApiCompatibility.CURRENT_CONTRACT_VERSION` → 0.15.0.
- Tests in `MultiVaultTest.kt`: happy-path (201 + dir/git + hot-add + survives restart), dup→409, non-empty-dir→409, bad-id→400. Full targeted run green (18 tests).
- LIVE VERIFIED end-to-end on :7619: create→201, hot-add visible, duplicate→409. (Smoke-test vault was created then CLEANED UP: removed from `~/htdocs/svod/dist/config.local.multivault.json` + `rm -rf ~/Svod/smoketest` + restart.)
- NB still NO delete-vault endpoint — removing a vault is manual (config edit + rm dir + restart).

## UI (svod-ui-macos, committed `eb0e83d` + `7042f95` on main + PUSHED to origin (FleetQ/svod-ui-macos), build green)
- `SvodClient.createVault(id:name:path:)` + `CreateVaultRequest` DTO; Live POSTs `/api/v1/vaults` (NOT vault-scoped, no `?vault=`); Mock appends to a static list.
- `VaultModel.createVault` = create → `load()` → `switchVault(newId)`.
- NEW `Features/Vaults/NewVaultView.swift` sheet: Name→auto-slug Identifier (editable, validates the pattern), optional location folder-picker, graceful fallback (`.notImplemented`/`.notFound` → "needs a newer Svod engine"; `.http(409,_)`/`.conflict` → "id exists or folder not empty"). Presented from RootView via `AppModel.newVaultPresented` (sheet-from-Menu never presents on macOS — same pattern as import).
- `VaultSwitcherView` menu is now **always shown** (was gated on `hasMultipleVaults`) so New Vault / Import are reachable with a single vault too. "New Vault…" gated on `!multiVaultUnavailable`.
- Clarified Import: it adds notes to the ACTIVE vault, NOT creates one. Relabeled switcher item ("Import notes into <vault>…"), sidebar button help, and ImportView title/body ("use New Vault for that").

## Process gotcha — harbormaster delegate_task ~600s wall
The first `delegate_task` (full engine feature) FAILED with `claude -p exit 1` after ~598s — a hard ~600s wall killed it mid-run. BUT it had already written ~all the code (uncommitted, auto_commit never fired because the process died first). Recovery: inspected the `svod` working tree directly (found the impl + contract bump present and `./gradlew test` GREEN), then re-delegated ONLY the small finish (add behavioral tests + commit) which completed in ~220s. LESSON: a "failed" big engine delegation may have done most of the work — check the working tree before redoing; scope large engine tasks small (they hit the wall). gradle is blocked by the context-mode Bash hook → run it via `ctx_execute(language:"shell")`; engine gradlew lives in `engine/`, not repo root. Probe engine HTTP via `ctx_execute` JS `fetch` (curl is blocked too).
