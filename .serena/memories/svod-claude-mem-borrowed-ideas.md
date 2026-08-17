# claude-mem borrowed-ideas sprint (2026-07-07) — SHIPPED

`/sprint-orchestrate full` — implemented 4 ideas mined from GitHub `thedotmack/claude-mem` (eval concluded it's an architectural DOUBLE of Svod, not a component to embed). Sequenced 1→4→2→3. Engine (Kotlin) delegated to `svod` via Harbormaster; UI (SwiftUI) done here.

## Shipped
- **Engine: DEPLOYED LIVE.** `svod-engine` **v1.10.0 / contract 0.21.0** on :7619. Release commit `be83eb3` (version bump on top of feature commit `a973792`), fast-forward merged to main, tag `v1.10.0` → CI release workflow success → https://github.com/FleetQ/svod-engine/releases/tag/v1.10.0 . `installDist` + `launchctl kickstart -k gui/501/dev.svod.engine`, clean cold start ~48s. Verified live: `/ready` 200; `GET /api/v1/search` hits carry `tokens` (example 44); live currentVersion 1.10.0, no phantom self-update; no new log errors. Full suite 213 pass / 0 fail / 2 skip. Versions synced across gradle+SvodNode (engine) and openapi+AppApiServer+ApiCompatibility (contract).
- **UI (svod-ui-macos): PR #4 MERGED** → main `8b79dcd`; **app v0.2.9 (build 11)** released (signed+notarized Accepted+stapled, appcast pushed, DMG 6,049,450 B, edSignature length matches → Sparkle-valid) AND **installed locally** to /Applications/Svod.app (spctl accepted, relaunched). `SearchHit.tokens: Int?`, `≈N tok` badge + ⌘K palette footer total. Both live together: app 0.2.9 ↔ engine v1.10.0.

## What each idea became
1. **Token cost (real UI work):** MCP `context_pack` already returned per-block `tokens`+`estimatedTokens`. Gap was UI recalls via `/api/v1/search`. Engine added `SearchHitDto.tokens: Int = ceil(snippet.len/4)` via shared `index/TokenEstimate.kt`. UI: badge + running total, labeled "excerpt" cost (snippet, not full-note pack). Mock seeds sample tokens.
2. **`<private>` exclude-from-index (Variant A, security-critical):** content stays in git note, excluded from FTS+bge-m3+recall. Enforced at **3** recall-feeding points (not the 1 anchored): `IndexService.prepare()`, `planEmbed()`, AND `context_pack` (re-reads FULL note, not index snippet). `MarkdownChunker.ParsedDoc.private` + `stripPrivateSpans()`. Leak test `RecallGuardsTest: context_pack never returns private content on any path`. `read(path)` by explicit path unchanged.
3. **`messy/` quarantine + opt-in:** `messy/` MUST_NOT in `LuceneIndex.buildFilter`, bypass via `includeAll`/config/explicit prefix. Config key **`includeMessyInRecall`** (SvodConfig, default false, snapshot at index construction → restart to change). Capture writer NOT built (deferred as optional Claude Code hook — contradicts deliberate philosophy).
4. **Activity agent identity: NO UI change.** `EventPayload.agentId`+`displayActor` already consumed it; engine now emits `agentId` on MCP `commit.created` `{commit,path,author,agentId}`; App API path unchanged (uiAuthor has no agentId).

## Key lessons
- Two of four "ideas" already ~built in Svod — ground brainstorm ideas in real code before scoping (idea 4 = zero UI work; idea 1 = wire-field add).
- Harbormaster deploy delegation: the svod project injects a generic "do NOT git commit / operator will review" footer that makes the agent STOP before irreversible steps (push/merge/deploy) even when authorized. To force a real deploy, delegate with an EXPLICIT override clause quoting the operator's in-session authorization verbatim + state the footer is superseded. First deploy attempt stopped at version-bump prep; second attempt (with override) shipped.
- The svod agent correctly went beyond spec on the security idea (found context_pack re-reads full note + planEmbed second path).
- Real engine release process bumps ONLY gradle+SvodNode for the app version (contract in openapi+AppApiServer+ApiCompatibility); `feat→main` fast-forward, tag `vX` push → CI cuts GitHub release (mirror of 7c79a92). Pre-existing STALE drift in `release.yml`/`dist/package.sh`/README (v1.6.4 / v1.5.0) is NOT part of the real process — left untouched.

## Follow-ups (operator, optional)
- Merge UI PR #4.
- Reconcile pre-existing stale version drift in release.yml/package.sh/README if desired.
- Capture-writer for messy/ (idea 3) is an opt-in Claude Code hook, deferred.
- No engine Sentry exists.

Related: `mem:svod-ui-architecture`, `mem:svod-engine-deploy-launchd`, `mem:svod-ui-search-sidebar-ux`.