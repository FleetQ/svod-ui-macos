# Svod UI — delete-vault feature (session 2026-06-22, follows mem:svod-ui-create-vault)

Adds deleting a vault from the macOS app, with confirmation, moving the folder to the macOS Trash.

## Engine (~/htdocs/svod, committed `4f70954` on main + PUSHED to origin (FleetQ/svod-engine), contract **0.16.0**, DEPLOYED live to :7619)
- NEW `DELETE /api/v1/vaults/{id}` (operationId `deleteVault`). Query `deleteFiles` (bool, default false): false ⇒ engine unregisters + leaves the dir on disk; true ⇒ also recursively deletes the dir. Response 200 `DeleteVaultResult{ id, path (the on-disk dir), filesDeleted }`.
- DESIGN SPLIT: engine does the LOGICAL removal only (release VaultLock + drain + drop from VaultManager + remove from persistent config via ConfigStore, survives restart) and returns the path; the **macOS app moves the folder to the OS Trash** (`FileManager.trashItem`) — headless engine can't do a proper cross-platform OS-trash. `deleteFiles=true` exists for headless/MCP callers.
- Rules: 409 deleting the DEFAULT vault or the LAST remaining vault (engine must keep ≥1 vault + a valid default); 404 unknown id.
- Tests in MultiVaultTest.kt: unregister+config+survives-restart+dir-left+path-returned; deleteFiles=true removes dir; default→409; last→409; unknown→404. Full targeted run green (23 tests).
- LIVE VERIFIED on :7619: create deltest→201, DELETE ?deleteFiles=true→200 `{path,filesDeleted:true}`, vault hot-removed, default-delete→409, unknown→404, no cruft left.

## UI (svod-ui-macos, committed `ca47d03` on main + PUSHED to origin (FleetQ/svod-ui-macos), build green)
- `SvodClient.deleteVault(id:deleteFiles:)` + `DeleteVaultResult` DTO (path optional for lenient decode). Live = `sendNoBody(DELETE /api/v1/vaults/{id})`, id path-encoded, NOT vault-scoped.
- `VaultModel.deleteVault` = engine delete → `FileManager.trashItem(path)` (guarded by `!filesDeleted`) → `load()` (re-points to default since deleted one may be active) → `app.didSwitchVault()` (reload panes).
- `AppModel.vaultPendingDeletion: Vault?` + `vaultActionError: String?` + `deleteVault(_:)` (maps `.notImplemented`/`.notFound`→"needs newer engine", `.http(409,_)`→"can't delete default/last").
- `RootView` owns `.confirmationDialog` ("Move <name> to the Trash? … restore from the Trash") + a failure `.alert` (keyed on the AppModel optionals via get/set Bindings) — same RootView-owns-the-modal pattern as sheets.
- `VaultSwitcherView` destructive "Delete <active>…" item — gated `!multiVaultUnavailable && hasMultipleVaults && !activeVault.isDefault` (don't show an action the engine will 409).

## Process note — harbormaster ~600s wall (SECOND occurrence, important)
Both engine delegations (create AND delete) reported `status:"failed"` with `claude -p exit 1` + "no stdin data received in 3s" after ~525–598s. BOTH had actually done ~all the work. The DELETE one had even **already committed** (`4f70954`) before the nonzero exit — so "failed" was a FALSE ALARM from the wrapper, not lost work. ALWAYS inspect the `svod` working tree + `git log` before re-doing: check `git status`, `git log --oneline`, run `./gradlew test --rerun-tasks` (UP-TO-DATE hides results — use --rerun-tasks to actually see PASSED lines). Recovery flow that worked twice: verify tests green via ctx_execute → (commit if not already) → installDist via ctx_execute → `launchctl kickstart -k gui/$UID/dev.svod.engine` → live-verify via ctx_execute JS fetch on :7619 → clean up any smoke-test vault.

## OPEN
- No "reassign default vault" endpoint yet — so the default vault can't be deleted at all (must always keep it). If the user wants to delete what is currently the default, they'd need a set-default endpoint first.
