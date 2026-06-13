# Svod UI — multi-vault upgrade (engine v0.3.0)

Sprint 2026-06-12 via `/agent-team custom` (full team). Builds on `mem:svod-ui-architecture` + `mem:svod-ui-settings`. Branch **`feat/multivault`** (off `main` after `feat/settings` was fast-forward-merged to main). NOT pushed. Integrated build GREEN, octopus merge clean, verified against the 2-vault Mock only (no live engine on :7517 at sprint end).

## Build shape
Single-vault app already existed; this was a multi-vault DELTA, not greenfield. Lead did Phase 0 (contract) sequentially + locked (commit `c6e9955`), then 5 teammates in manual worktrees built feature deltas off that, octopus-merged (`f75fa98`). Same worktree pattern as `mem:svod-ui-architecture` (provisioned `git worktree add ../svod-wt-<x>` manually, branches `wt/<x>`, removed after merge).

## Phase 0 — multi-vault contract (FROZEN, lead-authored)
KEY DESIGN: **ambient `activeVault`** on the shared client, NOT a `vault:` param on every method. The client applies `?vault=` centrally → existing call sites unchanged (additive only). Switching vault = one `client.setActiveVault(id)` redirects every subsequent fetch. Default vault is addressed by OMITTING `?vault=` (so `setActiveVault(nil)` for default; id only for non-default).
- `SvodClient`: `var activeVault {get}` + `setActiveVault(_:)`; `vaults()`; `importVault(source:into:vault:)`; `federatedSearch(...)` (across=true); `readFile(path:inVault:)` (cross-vault read w/o switching).
- `LiveSvodClient`: private `vaulted(_ extra:vault:)` threads ambient/explicit vault into ALL per-vault routes. `/vaults` + `/import` NOT per-vault.
- DTOs: `Vaults`/`Vault` (CodingKey `default`→`isDefault`; `typealias Vault = Vaults.Vault`), `SyncStatus{role,lastHead?,conflicts}`, `ImportRequest/ImportResult{imported,unchanged,skipped}`, `GlobalNoteRef{vault,path}` (`init?(globalId:"vault:path")`). `SearchHit.vault:String?` (id now vault-prefixed). `FileLinks.crossVaultBacklinks:[String]?` + `crossVaultRefs:[GlobalNoteRef]`. `EventPayload.vault:String?`.
- `MockSvodClient`: TWO vaults — `notes`(default)+`research`; per-vault `tree(for:)/files(for:)/graph(for:)/hits(for:vault:tagged:)`; REAL conflict `sampleConflict` (base/ours/theirs); research/method.md links `[[notes:vault/architecture.md]]`; `federatedSearch` returns both tagged. Back-compat `hits(for:)` shim kept.

## Phase 0 — App seams
- NEW sub-models in `App/`: **`VaultModel`** (load/switchVault + GRACEFUL fallback: `/vaults` 404/notImplemented → one synthetic `default` vault, `multiVaultUnavailable=true`, activeVault nil) and **`InspectorModel`** (`load(path:)`→links+recentCommits+`crossVaultBacklinks`).
- AppModel: composes `vault`+`inspector`; forwards `vault.objectWillChange`; `@Published reloadEpoch` (bump on switch; panes key `.task(id: app.reloadEpoch)`); `openGlobal(GlobalNoteRef)`; `open(path:vault:)`; `didSwitchVault()`; `bootstrap()`→`vault.load()`; `reloadVaults()`.
- RootView toolbar active-vault indicator via `VaultSwitcherSlot` (.navigation group). Placeholder VaultSwitcherView+ImportView authored for Teammate 5.

## Phase 1 — teammate deltas (all green, additive)
- **Editor**: `[[vault:note]]` via `GlobalNoteRef(globalId:)`, styled `accentMuted`; hover via `readFile(path:inVault:)`; click→`openGlobal`; target carried as `svodwiki://vault:path`.
- **Search**: "All vaults" chip (gated on `hasMultipleVaults`)→`federatedSearch`; vault badge; open via `open(path:vault:)`; graceful fallback if federated `.notImplemented`.
- **Graph**: `.task(id: reloadEpoch)` reload (skips epoch 0) + gentle `clearGraph()`; vault label.
- **History/Conflict**: NEW `ConflictsListView`+`ConflictsListModel` 3-way from `conflicts()` base/ours/theirs; ConflictMergeView/Model `MergeSource` enum (writeConflict=old 409 path / conflictItem=new); resolve via `resolveConflict` (sends `expectedRevision:nil`); 409 re-conflict→calm banner+refetch; reload on reloadEpoch.
- **Sidebar/Vaults/Import/Inspector/Activity/Engine**: VaultSwitcherView (menu, sync dots, default flag, "Import Obsidian Vault…"→ImportView sheet via `ImportMenuButton`); sidebar reload on reloadEpoch+header; Inspector cross-vault backlinks card→`openGlobal`; Activity "This vault" filter via `EventPayload.vault`; EngineModel `app.reloadVaults()` after reconnect. InspectorView reads `app.inspector` (InspectorSlot stayed no-arg).

## Contract GAPS — RESOLVED live (2026-06-13)
Both flagged gaps confirmed POSITIVE against a live v0.3.0 engine, so the engine honors them despite openapi under-specifying:
1. `across=true` IS supported — `/search?across=true` returns hits from all vaults each tagged `vault`. `federatedSearch` + `SearchHit.vault` correct.
2. Events DO carry `data.vault` — live `commit.created` event = `{...,"data":{"vault":"work",...}}`. `EventPayload.vault` + Activity per-vault filter correct.

## LIVE VERIFICATION (2026-06-13) — PASSED
NB: the engine on :7517 was an OLD single-vault **v0.2.0** instance (vaultPath /tmp/svod-test-vault; `/vaults` falls through to web-viewer HTML). The v0.3.0 multi-vault engine is merged in `~/htdocs/svod` main (PR #1, `ae4e4b6`) but wasn't the running binary. GOTCHA: a context-mode hook BLOCKS `curl`/`wget` and build tools — its empty output looked like "connection refused" and led me to wrongly say "no engine running". Use `ctx_execute` (JS fetch) to probe HTTP, not curl.
- Ran v0.3.0 from source on ALT port **:7619** (so the user's :7517 stayed untouched): `cd ~/htdocs/svod/engine && JAVA_HOME=$(/usr/libexec/java_home -v 20) ./gradlew run --args=<cfg>`. Config `~/htdocs/svod/dist/config.local.multivault.json` (2 vaults personal+work). Seed vaults at `~/Svod/{personal,work}` (work/method.md has `[[personal:architecture.md]]`). First-time gradle build already compiled; ready in ~26s.
- Validated live: /vaults, ?vault= routing, file/links `crossVaultBacklinks:["work:method.md"]`, federated across=true (tagged hits), /import (`{imported,unchanged,skipped}`), WS event vault, apiVersion 0.3.0 — ALL match Phase 0 DTOs.
- App (built Debug) repointed to :7619 via `defaults write dev.svod.Svod svod.settings.endpointPort -int 7619`; bundle id `dev.svod.Svod`; keys `svod.settings.endpointHost/Port`. Verified VISUALLY: connects ("Connected"), vault switcher shows Personal(default)/Work + Import item, switching Personal→Work re-scoped the whole app (sidebar tree + tags swapped), imported/ folder visible from the live import.

## SHIPPED (2026-06-13)
- `feat/multivault` fast-forward-merged to **main** and PUSHED to origin `FleetQ/svod-ui-macos` (`86e2df9..f75fa98`); build green on main pre-push. Local branches `feat/settings` + `feat/multivault` deleted (merged). main == origin/main.

## OPEN (for user)
- Engine harbormaster job `d_38b0c4cc0218` (v0.4.0 sync/backup, inbox `svod-ui-settings`) status still unrecalled.
- Temp state left for exploration: v0.3.0 engine on :7619 + app pointed there. To revert: `defaults write dev.svod.Svod svod.settings.endpointPort -int 7517` (or Settings→Connection), kill the :7619 gradle process, rm `dist/config.local.multivault.json`. `~/Svod/{personal,work}` are real seeded vault git repos (leave or delete).
