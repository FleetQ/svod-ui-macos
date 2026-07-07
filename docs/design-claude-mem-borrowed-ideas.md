# Design — claude-mem borrowed ideas

**Feature:** `claude-mem-borrowed-ideas` · **Branch:** `feat/claude-mem-borrowed-ideas` · **Date:** 2026-07-07
**Upstream:** `claudedocs/brainstorm_claude-mem_borrowed-ideas_2026-07-07.md` (requirements, frozen decisions)
**Scope decision:** all 4 ideas, sequenced 1→4→2→3. Engine (Kotlin) delegated to `svod` via Harbormaster; UI (SwiftUI) built in this repo.

## Forcing questions

**Who needs this? What are they doing today?**
The single user (owner of Svod) running agents against a personal memory vault. Today: recall returns opaque blobs with no cost visibility; secrets written into notes leak into agent recall + embeddings; lost session context because `remember` is manual; the Activity feed shows commits without agent identity or click-through.

**Narrowest MVP someone would pay for?**
Per-idea MVP, not gold-plated:
- **1 (token cost):** UI shows how many tokens a recall costs (engine already computes it for MCP `context_pack`).
- **4 (stream):** Activity feed shows *which agent* did each memory action + click → open that revision.
- **2 (`<private>`):** a `<private>` span / `private:true` frontmatter never reaches FTS, embeddings, or recall — content stays in the git note.
- **3 (auto-capture):** `messy/` becomes a real quarantine (excluded from default recall, opt-in toggle to include); an optional capture hook is documented, not forced.

**What makes someone say "whoa"?**
Writing a password in a note and watching it be invisible to every agent recall while still sitting in your own vault (idea 2). Clicking a live activity event and landing on the exact memory revision an agent just wrote (idea 4).

**How does it compound?**
`<private>` (2) is the guardrail that makes auto-capture (3) safe — you can capture aggressively because secrets never get captured. Token cost (1) feeds the Activity stream (4). Together they move Svod from "trust me" memory to *auditable, safe, legible* memory.

## Frozen decisions (from brainstorm, do not re-litigate)
- **`<private>` = exclude-from-index (Variant A).** Content stays in the committed note (source of truth); excluded from FTS + bge-m3 embeddings + `search`/`context_pack`. Visible to owner via App API (UI); hidden from MCP (agents). Variant B (strip-from-commit) rejected.
- **Auto-capture = `messy/` quarantine + opt-in.** No auto-writes into curated vault. Manual `promote`. Gated by `<private>` (never capture secrets).

## Non-goals (this sprint)
- No git-history scrubbing for retroactively-privatized notes (documented limitation).
- No LLM-summarization capture pipeline in the engine (engine has no LLM). Capture *writer* is an optional Claude Code hook, out of engine scope.
- No new `context_pack` App API endpoint / pack-recall UI — token cost rides the existing `/api/v1/search` path.
- No `sessionId` in events (none exists engine-side); agent identity only.

## Acceptance (sprint-level)
- Engine tests green; UI `xcodebuild` green, zero source warnings.
- Wire shapes in `architecture-*.md` match the delivered engine exactly (verified against live engine before ship).
- Security self-review pass on `<private>` recall paths (leak vectors).
