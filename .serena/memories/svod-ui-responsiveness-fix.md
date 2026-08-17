# Responsiveness fix: pane refresh on reconnect + history perf (2026-07-15)

Triggered by a user screenshot: **"Connected" but empty sidebar + "Couldn't load links" +
blank editor + "No commits yet"** on app 0.2.10, while the engine was warm (7-16ms responses).
Two independent problems, both fixed and shipped in **app v0.2.11 (build 13)** + **engine v1.11.1**.

## Problem 1 — panes don't refresh after (re)connect (APP, fixed)
Root cause: feature panes load on **mount**, which races ahead of the ASYNC engine
connection. A pane that fetched while the engine was still starting fails, and its
`.task` ran once so nothing re-drives it. `EngineModel.connect()` on success only called
`app.reloadVaults()` (vault LIST only) — never bumped `reloadEpoch`, never re-ran the
selectedPath panes. So a raced/failed initial load sat stale until a vault switch.
- Sidebar: `.task { if model.tree == nil { load() } }` (once) + `.task(id: reloadEpoch)`
  (guards `>0`, only bumped on vault switch) → empty forever if the mount-load raced.
- Inspector / History / Editor: `.task(id: selectedPath)` (selectedPath set at launch by
  reopen-last-note) → loaded once at mount, before connect → failed, no retry.

**Fix (commit `7e249d2`, 4 files):**
- `EngineModel.connect()` success path: added `app.refreshActiveVault()` (bumps
  `reloadEpoch`) on EVERY successful (re)connect → tree/graph/conflicts re-fetch.
- `InspectorView` + `HistoryView`: `.task(id: "\(selectedPath ?? "")|\(reloadEpoch)")` —
  re-run on note change AND on reconnect.
- `EditorView`: added `.onChange(of: reloadEpoch)` that reloads ONLY when
  `model.file == nil && !model.dirty` — self-heals a failed initial load but NEVER
  clobbers an unsaved draft (`EditorModel.dirty` flag). Editor also already had an
  ErrorStateView retry button.
- Trade-off: an extra tree/graph re-fetch on a warm launch (connect bumps epoch after the
  happy-path mount-load). Cheap; accepted for convergence robustness.

## Problem 2 — /file/history was 12.7s (ENGINE, fixed → v1.11.1)
Root cause: `GitRepo.log` used **jgit `LogCommand.addPath`** — jgit's path-filtered RevWalk
re-diffs every commit's tree along the path and can't use commit-graph / changed-path bloom
filters, so it walks the ENTIRE ancestry (12.7s on the 77k-doc `personal` vault). `max` was
already pushed down (`setMaxCount`) — the cap wasn't the issue; the per-commit tree-diff was.
**Fix:** `GitRepo.log` now shells out to native `/usr/bin/git log -n <max> --format=… -- <path>`
(`GIT_LITERAL_PATHSPECS=1`, 30s timeout, `\x1f`/`\x1e` delimited), with a **jgit fallback**
(`jgitLog`) if the subprocess fails. Native `git log` = ~0.08s vs jgit 12.7s (~150×). Default
cap 50→100 in SvodEngine.history + AppApiServer. Renames still not followed (unchanged).
Contract UNCHANGED (0.22.0) → no app DTO impact. Tests 219 / 0 fail. Deployed live; warm
history ~200-400ms (verified). Delegated to `svod` via Harbormaster (job history-perf),
tag `v1.11.1` (main `be23df4`).

## Release
App v0.2.11 (build 13): signed (PRICEX LTD EOOD) + notarized Accepted + stapled, appcast
pushed, DMG **6,140,758 B**, edSignature length matches. main `9bc7b11` (fix `7e249d2` +
bump `56098ef`). **Installed locally** to /Applications (spctl accepted, relaunched).
Pushed main BEFORE `release.sh PUBLISH=1` again → tag on the right commit.

## Lessons
- SwiftUI `.task`/`.task(id:)` runs once per id; a load that FAILS is not retried unless the
  id changes. For engine-backed panes, key on a value that changes on (re)connect (here
  `reloadEpoch`, bumped in `EngineModel.connect`), so panes converge to loaded whenever the
  connection (re)establishes — don't rely on mount-time load alone.
- Draft safety: any reconnect-driven editor reload MUST guard on `!dirty` (and unloaded) to
  avoid clobbering user edits.
- jgit path-filtered log is O(full history) on large repos regardless of maxCount — prefer
  native `git log -n` with a jgit fallback.

Related: `mem:svod-engine-deploy-launchd`, `mem:svod-ui-architecture`,
`mem:svod-recall-memory-sprint`, `mem:svod-ui-release-signing`.
