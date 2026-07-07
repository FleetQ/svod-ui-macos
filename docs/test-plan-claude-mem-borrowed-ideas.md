# Test plan — claude-mem borrowed ideas

## Idea 1 — token cost
- **Engine** (svod tests): `GET /api/v1/search` response includes `tokens` on each hit; value equals `estimateTokens(content)`; empty/blank hit → `tokens: 0`, never negative. Backward-compat: existing search test still passes (new field additive).
- **UI**: MockSvodClient hits carry `tokens`; search results render per-hit cost; running total = sum of shown hits; total updates as results change; no crash when `tokens` absent (decode optional-safe → 0).
- Edge: very long note (tokens > budget) still returns a hit with a large `tokens` value (search is not budget-capped, unlike pack).

## Idea 4 — Activity enrichment
- **Engine**: `commit.created` from MCP path carries `agentId`; App API path carries `agentId` when UI-author identity applies; watcher path has NO `agentId` (external). `agent.activity` unchanged.
- **UI**: feed row shows agent identity; missing `agentId` → "external"/"unknown" chip (no crash); click row with a `commit` → `SidebarModel.reveal(path)` fires and diff opens at that `commit`; dedupe by `data.commit` still holds (one row per commit).
- Edge: event with `path` but no `commit` (some emitters) → row shown, click is a no-op reveal (path only), no crash.

## Idea 2 — `<private>` (engine, security-critical)
- `frontmatter private: true` note → absent from `search` (keyword + semantic) and `context_pack` (MCP + App API); `read`/file endpoint still returns full raw note (owner-visible).
- `<private>span</private>` inside an otherwise-public note → the span's text never appears in any `search` snippet or `context_pack` block for any query (keyword hitting a private word returns nothing / non-private portion only); embeddings do not encode the span (semantic query on private text → no hit); the committed git blob still contains the span (history/read intact).
- Retroactive: public note edited to add `private:true` → next index pass removes it from recall; git history still holds old public revisions (documented limitation, asserted not silently "scrubbed").
- Concurrency: `<private>` handling does not break `expectedRevision` optimistic writes.
- **Leak audit (R1):** enumerate every recall path (`search`, `context_pack`, memory enumerate) and assert none echoes private content.

## Idea 3 — messy/ quarantine
- Note under `messy/` is EXCLUDED from default `search`/`context_pack` results.
- With `includeAll=true` OR `includeMessyInRecall=true` config → messy notes ARE returned.
- `promote(messy/x → curated/x)` → note now appears in default recall.
- Config default `includeMessyInRecall=false`; toggle persists across restart (ConfigStore).
- Non-messy notes unaffected (regression: existing recall results unchanged when no messy notes exist).

## Cross-cutting / regression
- Full engine suite green (PostgreSQL parallel-race caveat: re-run any lone failure with `--filter` before blaming the diff).
- UI: `xcodebuild -scheme Svod -configuration Debug` green, zero source warnings; app launches, connects live engine, holds WS.
- Live-engine DTO validation: `search` + events decode against the real engine incl. Cyrillic paths (per architecture memory).
