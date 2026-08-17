# Svod engine — fact classification on `remember` (v1.12.0/v1.12.1, contract 0.23.0) — 2026-08-01

## Overview

`remember` (the MCP promotion gate) used to check only a content hash: it stopped literal
repetition and nothing else, so two disagreeing facts about the same subject were stored as
unrelated `provisional` notes with no recorded relationship. It now **classifies** an incoming
memory against existing memory of the same `type`+`subject` before persisting.

Shipped as **v1.12.0** (feature) + **v1.12.1** (follow-up fix, below). Both merged to `main` with
green CI: PR #4 (`feat/memory-fact-classification`), PR #5 (`fix/contract-version-drift`).
Tags `v1.12.0` → `52b46db`, `v1.12.1` → `e430317`; both verified to point at HEAD == origin/main
(no tag drift). Rationale + thresholds + non-goal: **`docs/adr/0018-memory-fact-classification.md`**.

## Key patterns

**Classes and effects** — `NEW` writes as before · `DUPLICATE` no-op returning the existing note ·
`UPDATE` writes successor with `supersedes:` and revokes+links predecessor **in one commit** ·
`CONTRADICTION` persists **both**, linked by `contradicts:`, never overwrites either ·
`UNCERTAIN` persists with `needs-review: true`.

**Deterministic first, LLM only in the middle band** (in order, stop at first that settles):
1. normalized-text equality (case-folded, punctuation-stripped, whitespace-collapsed) → DUPLICATE
2. token overlap (Jaccard) — works with **no embedder**, which matters because `none`/BM25-only is
   the guaranteed baseline
3. embedding cosine — only when `Embedder.isActive`; failures are caught and fall back to (2)
4. `MemoryAdjudicator` — the ONLY place an LLM is consulted

| Signal | Duplicate | Ambiguous band | Unrelated |
|---|---|---|---|
| cosine | ≥ 0.97 | 0.82–0.97 | < 0.82 |
| Jaccard (no embedder) | ≥ 0.90 | 0.35–0.90 | < 0.35 |

Constants on `FactClassifier`, deliberately not config. **No deterministic rule ever invents a
semantic relationship** — rules say "same" or "unrelated"; only an adjudicator can say UPDATE or
CONTRADICTION. `MemoryAdjudicator` has **no implementation** and is `null` by default → engine
stays LLM-free, no new dependency; absent/unreachable/declining ⇒ `UNCERTAIN`, never a guess.

**Retrieval** — the EXISTING hybrid path (`IndexService.search`, BM25+kNN+RRF), `type` filter with
**`includeAll = true`** (essential: `fact`/`policy` enter `provisional` and are hidden from ordinary
recall, yet are exactly what must be compared against). Retired candidates (`status: revoked` or
carrying `superseded_by`) are dropped. **Subject scoping happens AFTER retrieval** because `subject`
is note frontmatter and is *not* an indexed field — "no new index" was a hard constraint.

**Plan off-actor, validate + apply on-actor** (the load-bearing concurrency decision, chosen by the
user over running everything on-actor). Classification is impure and slow (Lucene, possibly-remote
embed, possibly an LLM call); the write-actor is one thread running blocking lambdas, and ADR-0017
established — `IndexConcurrencyTest` proves — that **writes never wait on embedding**. So:
`FactClassifier.plan(...)` runs off the actor and returns `guards` (path→revision of every candidate
the verdict was computed against); `SvodEngine.writeGuarded(files, guards, author, message)` runs ONE
actor task that re-validates guards against live blob ids then writes all files in one commit.
Mismatch ⇒ `GuardedWrite.Stale` ⇒ caller re-plans **once**, then returns `conflict`. Same shape as
`writeBatch(expected=)` / `applyMerge(expectedHead=)`.
Guard limit (documented honestly in the ADR): catches *mutation* of examined candidates; a candidate
**created** concurrently has no prior revision to guard and can be missed. What IS absolute — identical
content+type hash to one deterministic path, so concurrent identical `remember`s collide, losers go
Stale, re-plan, and dedup to exactly one note.

**Security fix folded in**: the secret scanner ran at write time, so with classification in front of
the write, content would reach a **remote** embedder or an LLM before being refused from disk.
`remember` now calls `engine.scanSecrets` up front. Regression-tested (adjudicator never sees it).

**MCP response** gains `classification`, `relatedNote`, `confidence` (+ `rationale`, and
`contradicts`/`needsReview` where applicable). Every pre-existing field (`status`, `path`, `type`,
`memoryStatus`, `revision`, `commit`, `superseded`) keeps its meaning — no breaking change; the
pre-existing `MemoryToolsTest` passes untouched. An explicit `supersedes` argument short-circuits
inference to caller-declared `UPDATE`.

## File locations

- `engine/src/main/kotlin/dev/svod/engine/memory/FactClassifier.kt` — NEW: `Classification` enum,
  `MemoryAdjudicator`, `MemoryCandidate`, `ClassificationPlan`, thresholds, cosine/jaccard/normalize
- `engine/src/main/kotlin/dev/svod/engine/core/SvodEngine.kt` — `writeGuarded` + `doWriteGuarded`
- `engine/src/main/kotlin/dev/svod/engine/core/Model.kt` — `sealed interface GuardedWrite`
  (`Applied` / `Stale` / `Blocked`)
- `engine/src/main/kotlin/dev/svod/engine/mcp/SvodTools.kt` — `remember` rewiring; ctor gained an
  optional trailing `adjudicator: MemoryAdjudicator? = null` (existing 4/5-arg callers unaffected)
- `engine/src/main/kotlin/dev/svod/engine/index/IndexService.kt` — `activeEmbedder()` accessor
- `engine/src/test/kotlin/dev/svod/engine/mcp/MemoryClassificationTest.kt` — NEW, 13 tests
- `docs/adr/0018-memory-fact-classification.md`

## Constraints / non-goal

**Not KG entity resolution.** Scope is per-subject fact consistency only. No coreference, no subject
normalization ("prod-db" vs "production database" are different subjects), no transitive reasoning,
no subject extraction from free text. A memory with no `subject` is compared by `type` alone. The
classifier returns `UNCERTAIN` rather than pretending to resolve an entity.

Expect `UNCERTAIN` to be **common** on `none`-embedder installs with no adjudicator — the Jaccard
band is wide. That is the intended failure direction: a flagged note is recoverable, a wrong `UPDATE`
that revoked a good memory is not.

## Gotchas (all cost real time this session)

- **A Kotlin `@Test` that compiles to non-`void` is SILENTLY not collected by JUnit.**
  `fun x() = runBlocking { … }` infers its return type from the block's last expression; ending on
  `assertNotNull` (which returns T) yields `public final Object x()` → the test never runs, with a
  green build and no warning. Caught only because the report said `tests=11` for 12 `@Test`s. Fix:
  `fun x(): Unit = runBlocking { … }`. **Never trust "BUILD SUCCESSFUL" as evidence a new test ran** —
  check the `tests=` attribute in `build/test-results/test/TEST-*.xml`, or `javap -p` the class.
  Also see `mem:kotlin-junit-silent-skip` equivalent in auto-memory.
- **The contract version had THREE publication points** and v1.12.0 bumped only two →
  `/update/check` said 0.23.0 while `/settings` advertised 0.22.0, and the macOS app
  feature-detects on `/settings.apiVersion`. Fixed in v1.12.1: `AppApiServer.Config.apiVersion` now
  **derives** from `ApiCompatibility.CURRENT_CONTRACT_VERSION`, and `VersionConsistencyTest` compares
  the gate, `/settings`, and `contract/openapi.yaml`. Verified in both directions (green as
  committed; injected drift fails with a message naming both files). Same class as the
  `currentAppVersion` drift of v1.8.1/v1.11.3 — see `mem:svod-engine-deploy-launchd`.
- **Local deploy ordering is load-bearing**: launchd runs the engine with classpath
  `engine/build/install/svod-engine/lib/*`. `./gradlew clean` deletes that directory, so it must run
  **before** `installDist`, never after — use a single `./gradlew clean installDist`, then
  `launchctl kickstart -k gui/501/dev.svod.engine`. Verify nothing is running from a dir before
  deleting it (`lsof +D`, `ps -Ao pid,command | grep java`).
- **Cold start observed 7.5 min** on the first restart (upper end of the documented 25s–7.5min
  range; port 7619 is NOT bound for most of it — the process looks idle at ~0.6% CPU but is fine),
  then **48s** on the next restart with a warm index. Poll `/ready` with a **JS fetch**, not curl
  (context-mode hook blocks curl).
- **`du` is aliased to `dust`** in this shell and errors on a missing path — use `/usr/bin/du`.
- Build sizes for reference: `engine/build` 1.9G before a clean → 153–171M after; `dist/build` 258M.

## Verification

237 tests pass / 0 fail / 2 skip (2 skips pre-existing). Live on :7619 after deploy:
`/ready` 200 · `/settings apiVersion = 0.23.0` · `/update/check` `currentContract=0.23.0`,
`current=latest=1.12.1`, `updateAvailable=false`, `compatible=true`.
NB: at write time the v1.12.1 release workflow was still uploading macOS/Windows assets (2 of 6
published); the v1.12.0 workflow completed green with all assets.

## Last updated

2026-08-01
