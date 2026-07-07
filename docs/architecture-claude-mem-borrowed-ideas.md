# Architecture — claude-mem borrowed ideas

Source of truth for the engine delegation and the UI build. File:line anchors from the engine map (svod project, read-only ask 2026-07-07) and this UI repo.

## Pinned engine↔UI wire contract

The engine changes below are additive and backward-compatible. New fields are the contract the UI is built against.

### Idea 1 — token cost
- **Engine, MCP `context_pack`:** ALREADY returns `{ mode, tokenBudget, estimatedTokens, blocks[] }`, each block `{ path, heading, content, score, commit, author, tokens }` (`SvodTools.kt:159-166`, `estimateTokens` ~4 chars/tok `:176`). **No change needed** — agent-facing progressive disclosure already satisfied.
- **Engine, App API `GET /api/v1/search`:** today `SearchResultDto{ mode, hits[] }`, `SearchHitDto{ path, heading, snippet, score, matchedKeyword, matchedSemantic, tags, vault }` (`AppApiServer.kt:330`). **CHANGE:** add `tokens: Int` to `SearchHitDto`, populated via the same `estimateTokens` used by `contextPack` (estimate on the hit content/snippet). Additive → existing clients ignore it.
- **UI:** `SearchHitDto` (Networking DTOs) mirror `tokens: Int`. Search results + Inspector recall show per-hit token cost + a running total.

### Idea 4 — Activity stream enrichment
- **Engine event payloads** (`data` is ad-hoc JsonObject, `EventBus.kt:24/41`):
  - `agent.activity` (MCP) ALREADY `{ agentId, tool, path, commit }` (`SvodTools.kt:299,376`). No change.
  - **CHANGE `commit.created`:** add `agentId` where an agent is present.
    - MCP path `{ commit, path, author }` → `{ commit, path, author, agentId }` (`SvodTools.kt:300,379`; `agent.agentId` in scope via `AgentRegistry`/`AgentIdentity`, `mcp/Agent.kt`).
    - App API path already `{ vault, commit, path, author, tool }` (`AppApiServer.kt:786`) → add `agentId` if a UI-author identity applies (else omit; `author` already there).
    - Watcher path `{ commit, author:"external" }` (`FileWatcher.kt:72`) → leave; no agent (external git). UI treats missing agentId as "external/unknown".
- **UI:** `EventPayload` decodes optional `agentId: String?`. `ActivityFeedView` shows agent identity (fallback "external"). Click a row → `SidebarModel.reveal(path)` + open diff at `commit` (reuse existing reveal + revision diff; `data.path`, `data.commit` already decoded).

### Idea 2 — `<private>` (engine only)
- **Single hook: `IndexService.prepare()`** (`index/IndexService.kt:647`), the sole indexing apply point (`applyDocs :670`, `LuceneIndex.upsertFile :106-128` writes both FTS `text` and kNN `vec`).
- Frontmatter parse exists (`MarkdownChunker.parse` → `ParsedDoc{frontmatter, body, tags, created}` `:48,61`; `memoryMetaOf(doc)`).
- **Behavior:**
  - `frontmatter private: true` → in `prepare()` after parse, short-circuit to `applyDocs(path, null)` (removes from index) while the git note/blob is untouched.
  - `<private>…</private>` **span** → strip spans from `body` before `MarkdownChunker.chunk()` so they never become chunks (never hit FTS or embeddings); committed bytes unchanged.
- **Channel split:** exclusion is at the index layer → `search`/`context_pack` (MCP + App API `/search`) never return private content. App API `read`/file endpoints return the raw note (owner sees their own content in UI). No UI change required for MVP.

### Idea 3 — `messy/` quarantine + opt-in (engine)
- `messy/` namespace + `promote(from,to)` exist (`SvodEngine.promote :157`, source-under-`messy/` enforced; MCP `promote` `SvodMcpServer.kt:222`).
- Recall does NOT exclude `messy/` today; only lifecycle-status exclusion exists (`LuceneIndex.kt:204-209`, bypass via `SearchFilters.includeAll` `SearchModels.kt:16`).
- **CHANGE:** add a `messy/` **pathPrefix exclusion** in `LuceneIndex.buildFilterQuery` (sibling of the status filter near `:204`), applied to default recall, bypassed when `includeAll=true` OR a new config toggle is set.
- **Config:** add `includeMessyInRecall: Boolean = false` to `SvodConfig`/`ConfigStore` (`lifecycle/SvodConfig.kt`, `ConfigStore.kt`).
- **Capture writer:** OUT of engine scope this sprint. Optional Claude Code `SessionEnd` hook (documented deliverable) may write summaries to `messy/` via MCP `write`; engine only guarantees quarantine.

## UI change map (this repo)
- `Svod/Networking/` DTOs: `SearchHitDto` + `tokens: Int`; `EventPayload` + `agentId: String?` (`Events.swift`).
- `Svod/Features/Search/` + `Svod/App/SearchModel.swift`: render per-hit token cost + running total.
- `Svod/Features/Inspector/InspectorView.swift`: token cost on recall/links surface (minimal).
- `Svod/Features/Activity/ActivityFeedView.swift` + `Svod/App/ActivityModel.swift`: agent identity chip + click→reveal-at-revision. `ActivityModel.events(for:)` already filters by path.
- `MockSvodClient`: sample `tokens`/`agentId` so previews/offline build cover new fields.

## Data flow (unchanged contracts respected)
- UI recall: `RootView ⌘K → SearchModel → client.search → GET /api/v1/search` (now with `tokens`).
- Activity: `EngineModel` WS `/api/v1/events → ActivityModel.ingest` (now agentId-aware).
- No new endpoints; no engine-behavior invention beyond the additive fields above.

## DELIVERED (engine, svod branch `feat/claude-mem-borrowed-ideas`, 2026-07-07)
Full engine suite green: **213 tests, 0 failed, 2 skipped** (ONNX/Ollama integration, need local models). Branch NOT committed/merged/deployed — awaiting review.
- **Idea 1:** `SearchHitDto.tokens: Int` (default 0, additive) = `ceil(snippet.length/4)` via new shared `index/TokenEstimate.kt` (same estimator as `context_pack`). Contract `openapi.yaml` `SearchHit.tokens` added (not required) — **may need a contract version bump** per convention.
- **Idea 4:** MCP `commit.created` → `{commit, path, author, agentId}`. App API `commit.created` unchanged (uiAuthor has no agentId). New test `commit_created carries agentId`.
- **Idea 2:** exclusion enforced at **three** recall-feeding points, not one — `IndexService.prepare()`, `planEmbed()` (background embed), AND `context_pack` (which re-reads the FULL note, not the index snippet). `MarkdownChunker` gains `ParsedDoc.private` + `stripPrivateSpans()`; raw `.body` kept for revoke/dedup. Leak test `context_pack never returns private content on any path` (RecallGuardsTest). `read(path)` by explicit path unchanged — private stays in the note, recall-invisible only.
- **Idea 3:** `messy/` MUST_NOT in `LuceneIndex.buildFilter`, bypassed by `includeAll` / config toggle / explicit `messy/` prefix browse. Config key **`includeMessyInRecall`** (SvodConfig, default false, persisted, snapshot at index construction → restart to change). Capture writer intentionally NOT built (out of scope).

### UI reconciliation (done)
- `SearchHit.tokens: Int?` decodes the additive `tokens` (engine always sends ≥0). Badge shows only when > 0. Copy corrected to "excerpt" wording (engine estimates the snippet, not full-note pack cost).
- `EventPayload.agentId` / `displayActor` already consume the enriched `commit.created`. No UI change needed.

## Risk register
- **R1 (security, idea 2):** a recall path that bypasses the index (e.g. reads note body directly into a pack) would leak private content. Mitigation: audit every recall path returns index-derived content only; test that `search`/`context_pack` never echo a `<private>` span.
- **R2 (contract drift):** UI built to pinned shapes before engine lands. Mitigation: engine delegation must return final shapes; reconcile before ship; MockSvodClient covers the fields.
- **R3 (idea 3 emptiness):** quarantine without a capture writer = a feature with no producer. Accepted: MVP is the safe quarantine; capture hook documented as opt-in follow-on.
