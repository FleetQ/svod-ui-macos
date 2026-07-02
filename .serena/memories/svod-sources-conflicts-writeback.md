# Svod — source-sync divergence fix: conflicts + resolve (0.19.0) & write-back (0.20.0) — 2026-07-02

User asked "агентска редакция изчиства ли се от файловата система?" → NO (verified live: edits become conflicts, never clobbered), but exposed two real gaps: conflicts were invisible-forever and there was no path back to the project file. Fixed in two phases, both live on :7619 (apiVersion **0.20.0**), app **v0.2.5**.

## Phase 1 — persisted conflicts + resolve (contract 0.19.0, engine commit `0f84f77`)
- `ExternalSource.conflicts` persisted after each sync → GET /sources shows diverged paths.
- `POST /api/v1/sources/{id}/resolve {path, strategy: takeExternal|keepVault}`.
- **KEY DESIGN — two-sided manifest**: `SyncedState{ext, vault}` per path (was a single blob id). Single-blob made keepVault IMPOSSIBLE (re-baseline to vault rev ⇒ next sync's "update" branch clobbers the kept edit with the OLD external content). Sync classification: create / unchanged / quiet-kept-divergence (both sides == baseline) / update (only if clean baseline m.vault==m.ext AND vault untouched) / conflict. keepVault ⇒ kept edit quiet while external is still, NEW external change re-surfaces as conflict. Legacy manifests load as (v,v).
- Prune guard tightened to clean-baseline only.
- UI (app 0.2.4, commit `82c4a08`): "Diverged" card per source, per-path Keep mine / Take external; no version gate needed (conflicts decode empty pre-0.19).

## Phase 2 — opt-in write-back (contract 0.20.0, engine commit `7c1de59`)
- `ExternalSource.writeBack`: vault edit + external unmoved since baseline ⇒ vault working-tree copy written OVER the external file (temp+ATOMIC_MOVE), manifest re-baselined, reported as `pushed`. Both-moved stays conflict. Vault-created files NOT materialized externally.
- **Live trigger**: `SourceWatchManager` subscribes to `commit.created` on the EventBus → debounced (3×debounceMs) sync of that vault's writeBack sources. Events without vault tag (MCP SvodTools omits it — App API includes it) fan out to all vaults with writeBack sources. Own sync-author commits skipped (loop guard); pushes create no vault commit.
- LIVE VERIFIED: App-API vault write → external file updated in **905ms**, no manual sync; both-moved → external untouched + conflict persisted.
- UI (app 0.2.5, commit `1bd4703`): "Write my edits back (two-way)" toggle (add form + per-source, gated `apiVersionAtLeast(0,20)`), "pushed back" in sync summary. SvodClient registerSource/updateSource gained `writeBack` param + pre-0.20 convenience overloads (the established pattern).

## Gotchas learned
- AppApiContractTest has a HARDCODED implemented-routes list — new route ⇒ add there or exact-match assert fails. MCP tool count is hardcoded in McpHttpIntegrationTest/McpTlsTest (now 15).
- Engine cold start VARIES WILDLY: 25s–7.5min. The long tail is methvin DirectoryWatcher hashing the whole big personal vault at boot (thread dump: Murmur3F in initWatcherState, RUNNABLE — not stuck). Poll /ready up to ~8 min before concluding failure; `kill -QUIT <pid>` → thread dump in engine.out.log is the diagnostic.
- MCP events (SvodTools) don't carry `data.vault` — UI Activity per-vault filter misses agent commits; possible follow-up.
- Известен остатък: engine 0.20.0 е само на main + deployed local; няма tagged engine release (последният е v1.8.1). Cut v1.9.0 when desired.
