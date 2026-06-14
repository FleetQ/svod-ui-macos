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
- `feat/multivault` → **main** + PUSHED to origin `FleetQ/svod-ui-macos`. Subsequent commits (UI fixes + UI/UX-audit fixes, Serena memories, README) all merged to main + pushed; HEAD `673af51`. main == origin/main. All feature branches deleted; only `main` remains. No `develop`, no submodules — main IS the integration/prod branch. **Repo is now PUBLIC** (`FleetQ/svod-ui-macos`); README rewritten for the built public app and the old "personal / out-of-product-scope / unsupported" framing was REMOVED at the user's request (only the factual "separate repo, contract-decoupled, ADR-0002" note kept). License still TBD. Ship flow each time: branch → fix → build green → FF-merge to main → delete branch → push (user also has a `/git-sync-branches` skill).

## POST-SHIP UI FIXES (2026-06-13) — SwiftUI gotchas worth remembering
Three small fixes after user testing the live app (all on `fix/diff-responsive`, merged to main):
1. **Responsive diff** (`DiffView.swift`): side-by-side used FIXED 380pt columns + `.fixedSize(horizontal:true)` text → never adapted; a new/added file left the empty "old" column 380pt wide, pushing the change off-screen. FIX: `GeometryReader` → columns flex to `(width-1)/2`, vertical-scroll only, text wraps (`.frame(maxWidth:.infinity, alignment:.leading)` instead of fixedSize); below `minSideBySideWidth = 680` auto-collapse to the unified single column (which also wraps now).
2. **Import did nothing** (`VaultSwitcherView`): a `.sheet` attached to a Button **inside a `Menu`** NEVER presents on macOS (menu is a separate context, tears the button down on dismiss). FIX pattern: don't present sheets from inside a Menu/toolbar item — add `AppModel.importPresented` flag, menu/sidebar buttons just set it, and `RootView` owns the `.sheet(isPresented:$app.importPresented)` (same reliable path as the conflict sheet). `ImportView` got a Done button + `.cancelAction` Esc + `app.refreshActiveVault()` (bumps reloadEpoch) post-import so new files show.
3. **Duplicate sidebar toggle** (`RootView`): `NavigationSplitView` ALREADY supplies a sidebar-toggle button + View▸Show/Hide Sidebar (⌃⌘S). Our extra `sidebar.left` button in the `.navigation` ToolbarItemGroup was a second one. FIX: removed ours, kept only `VaultSwitcherSlot` in that group. (`.inspector` does NOT auto-add a toggle, so the custom `sidebar.right` inspector button stays.)
GENERAL LESSON: `.sheet`/`.popover` from toolbar-item or Menu-content views is unreliable on macOS — present from the main RootView via an AppModel flag.

## ENV GOTCHA (verification)
`screencapture` returns a BLACK frame when the session display is asleep/locked (worked earlier same session, then went black). UI automation via `osascript ... click at {x,y}` is FLAKY here — it intermittently triggers Stage Manager / focuses other apps (1Password) when a click lands outside the window. AX element clicks (`click button N of ...`) are more reliable than coordinate clicks but still hit menu/disclosure quirks. Don't rabbit-hole on visual verification; trust green build + sound pattern.

## SESSION 2 (2026-06-13/14) — engine v1.0, GitHub backup, Sources, markdown+tables

### Engine progression (~htdocs/svod, shipped same day; releases LAG main)
v0.5.0 sync/backup ops aligned to UI wire shapes → v1.0.0 stable (native app-images macos-arm64/linux-x64/windows-x64, ~205MB **jpackage bundle w/ JRE** so onnx-local works) → v0.6.0 contract (`ImportRequest.followSymlinks` + NEW `sources` endpoints) → v1.0.1 + rc's (GraalVM native fixes, NOT features). **Features land on main commits BEFORE a release build** — to test newest, build from source (`gradlew run`) on alt port, or download the release app-image. The launchd :7517 engine was stale v0.2.0; I ran current from source on **:7619** and pointed the app there (Settings→Connection / `defaults write dev.svod.Svod svod.settings.endpointPort 7619`).

### Sync/backup deploy + verify (PASSED live)
Deployed v1.0.0 jpackage: `~/svod-engine-v1/SvodEngine.app/Contents/MacOS/SvodEngine <config>`. All 5 endpoints live (200, shapes == UI DTOs): GET /sync/config, PUT /settings/backup, POST /backup/now|sync/now|maintenance/reindex. Guards: inline `user:pass@` →422, unreachable remote →409 (not 500). `GET /vaults` items carry `sync` dot.

### GitHub OAuth backup (`Svod/Features/Settings/GitHubBackup.swift`)
One-click "Connect GitHub" in SyncBackup panel. **OAuth Device Flow**, public clientID **`Ov23liNkXS7CerjNmDa8`** (registered OAuth App "Svod", Device Flow enabled, NO client secret; homepage/callback can be the repo URL — unused by device flow). Flow: device code → browser authorize → poll token → ensure private `svod-backup-<vault>` repo (GitHub API) → store authed URL.
**SECURITY (commit-review finding, FIXED):** originally `security add-generic-password -A` (Keychain) — flagged for secret-in-argv + over-broad `-A` ACL. Now writes the authed URL to `~/Library/Application Support/Svod/backup-<vault>.remote` **chmod 0600** and gives the engine a **`file:` ref** (git credential.store pattern). Raw token never crosses the loopback App API. Engine resolves remote via `Secrets.resolve` at push (env:/file:/keychain: refs). Private-repo backup = HTTPS token via a Secrets ref; **SSH not supported** (no jgit-ssh bundled). Backup pushes to `refs/svod/backup/<vault>`.

### Sources UI (`Svod/Features/Settings/SourcesSettingsView.swift`) — Settings → Sources
Re-syncable external sources (engine v0.6.0). DTOs `ExternalSource`, `RegisterSourceRequest`, `SourceSyncResult{created,updated,unchanged,conflicts,orphaned,deleted,skipped,error}` (lenient decode). Client: `listSources/registerSource/removeSource/syncSource/syncAllSources` (per-vault; LiveSvodClient `sendNoResult` for the 204 DELETE). external-wins-unless-locally-edited. **Chosen over blanket `followSymlinks`** — followSymlinks WORKS but on the user's vault materialized 7000+ files (project `docs`/.claude trees the symlinks point at). Sources = register only the dirs you want.

### Markdown rendering overhaul (Editor)
- **Proportional body font** (was monospace everywhere); mono only for code/inline-code/tables. Headings `systemFont`.
- `[text](url)` styled+clickable (http→browser); `![alt](url)` styled; task lists `- [ ]`/`- [x]` (done=green+struck); `~~strikethrough~~`; aliased `[[a|b]]` shows alias (dims `a|`).
- **Delete note/folder** via right-click context menu + confirmation. Engine requires `expectedRevision` for DELETE → read rev first, then delete (`trash()`). Folder = recursive soft-delete to `.trash/`.

### TABLE GRID RENDERER (`Svod/Features/Editor/TableRenderer.swift`) — hard, many iterations
Custom **`TableLayoutManager: NSLayoutManager`** renders markdown tables as an aligned grid WITHOUT touching source.
- Highlighter tags each table source line `.svodTableLine` (TableLineInfo: table, blockId, blockRange, isFirstLine, **gridRow** [header=0, data 1.., separator=-1]). `MarkdownTable.parse` uses a **PIPE-AWARE split** (ignore `|` inside `[[ ]]`, inline code, `\|`) — naive split breaks `[[a|alias]]` cells. Per-cell `display`(alias) + `target`(svodwiki://|url).
- LM **nulls raw table glyphs** (shouldGenerateGlyphs delegate, keep newlines) except the revealed block; draws each grid row at its OWN line fragment (drawRow into `frag.height`).
- **AppKit GOTCHAS (each a fixed bug):** (a) reserving all height on the first line = one giant line fragment → scroll/overlap garbage; (b) `shouldSetLineFragmentRect` delegate height is NOT reliably honored → set row **height via PARAGRAPH STYLE `minimumLineHeight`** in the highlighter instead (survives because applyFocusDimming re-runs highlight last); separator stays collapsed by the delegate (height 0 works, editable when revealed); (c) wikilink `.underlineStyle` paints across cells even with null glyphs → STRIP underline/strikethrough on table ranges; (d) draw into ACTUAL `frag.height` (not a computed constant) so borders never bisect text.
- Caret-aware reveal: block under caret shows raw editable (`updateTableReveal` on selection → `lm.setRevealed` + invalidate). Clickable cells: `HoverTextView.mouseDown` → `lm.link(atContainerPoint:)` → `openLink`.
- Final styling: zebra rows, faint vertical column separators (no per-cell grid), header tint+underline, +14pt row air.

## OPEN (for user)
- Engine: current is **v1.0.1** (released) but newest features (sources/followSymlinks) need a v0.6+ build. App is pointed at the from-source engine on **:7619**; to use normal setup, deploy v1.0.x to :7517 (replace launchd v0.2.0) or keep app on :7619 via Settings→Connection.
- A public GitHub OAuth App "Svod" exists (clientID baked into the app).
- `~/Svod/personal` is messy from import tests + the user's root import (`AGENTS.md` etc. at root, `obs-daily/`, `ext/contract/`). Offer to clean for a fresh real import.
