# OpenViking (volcengine) evaluation — research only, nothing implemented (2026-09-15)

Report: `claudedocs/research_openviking_2026-09-15.md`. Same method as `mem:svod-palette-borrowed-ideas-research`:
ground every idea in what Svod already has before scoping.

**What it is:** "context database for agents", Python server + Rust CLI, AGPL-3.0 (examples/ incl. the Claude Code
plugin are Apache-2.0). Everything is a `viking://` virtual FS (resources / memories / skills); every directory gets
LLM sidecars L0 `.abstract.md` (256 chars) + L1 `.overview.md` (4000); retrieval recurses into directories with score
propagation; session commit archives + LLM-extracts memory. LLM everywhere — opposite of Svod's LLM-free index.

**Verdict:** don't borrow the architecture. Borrow the Claude Code integration shape and a few summary-metadata ideas.

**BUG found in Svod during the comparison [observed]:** capture stores only the start of each session. The Stop hook
fires after EVERY response, but `POST /api/v1/memory/capture` dedups on `sessionId` and returns the existing note
without updating it (`AppApiServer.kt:882-887`). All 8 live captured sessions are 965 B–5.8 KB. Fix: upsert by
sessionId, or capture on `SessionEnd` + `PreCompact` (what OpenViking does).

**Ranked ideas (operator decides):**
1. Auto-recall `UserPromptSubmit` hook — none exists for Svod. Server side already there (`context_pack tokenBudget`).
   OV defaults worth copying: score ≥0.35, skip prompts <3 chars, 1600-token block, cross-turn dedup of paths shown
   in the last 5 turns, prefer abstract.
2. Capture on PreCompact/SessionEnd (with the bug fix).
3. Summary coverage + human edits: `Community.addedSinceSummary` already ≈ OV `pending_child_changes`; prompt coverage
   is told to the model (`GraphService.kt:333`) but NOT persisted; rebuild overwrites everything so a manual summary
   edit cannot survive. Same as Palette idea C6.
4. MCP `tree` (with descriptions) / `grep` / `glob` — Svod has only `list(pathPrefix)`.
5. Experience memory (cases→trajectories→experiences); OV claims +6.9/+11.9pp on tau2-bench [claimed]. After 1+2.
6. Opt-in LLM query rewrite for cross-lingual (retrieval-quality C5), measure on leg V.
7. Community-first hierarchical retrieval — not before eval; must stay out of `search()` (invariant A3).

**Rejected:** viking:// URIs/VFS, per-directory LLM sidecars at ingest, `ov compile` in engine (engine = data plane),
multi-write backends, VikingBot. Per-resource ACL maybe later for the company vault.
