# Svod — graph-aware recall (Ниво 1 + Ниво 2) — SHIPPED 2026-08-17

Engine **v1.15.0** / contract **0.24.0** and app **v0.2.16 (build 18)** are RELEASED and live.
Deliberately stops short of full GraphRAG — no LLM entity extraction over chunks, none stubbed.

Engine PR #8 (merged `d634047`, release tag `v1.15.0` → `28d2fe7`, workflow success, 6/6 assets).
App PR #5 (merged `4e506e4`, tag `v0.2.16` → `ceef09d`, appcast commit `b7f3580`).
Docs: `svod/docs/{design,architecture,test-plan}-graphrag.md`.

## The decision that made it cheap

MS-style GraphRAG spends nearly all its cost **inferring** a graph from unstructured text (an LLM call
per chunk — ~79k here). Svod already has a human-authored graph. Measured: only **665 of 3,469 notes
(19%)** carry a wikilink, so wikilinks alone are not enough — but **kNN similarity between notes**
closes the gap for **zero LLM calls and zero embedder calls**, because `IndexService.noteVector(path)`
mean-pools chunk vectors the indexer already stored (`LuceneIndex.existingVectors` reads back
`VEC_BYTES_FIELD`). Result on `personal`: 732 wikilink edges → **14,315 edges, 100% coverage**.

Ниво 3 is NOT built. The blocker is the machine, not the design; RunPod would remove it but converts
it into a disclosure decision. NB: `secretScanning` defaults to false but **is `true` in the operator's
live config**, so the vault IS scanned on commit — less risky than a first read of the default suggests.

## Shape

New package `engine/.../graphrag/`, SEPARATE from the frozen `graph/` package (LinkGraph stays the
wikilink navigation surface): `NoteGraph`, `NoteGraphBuilder`, `CommunityDetector` (**Louvain**, not
Leiden — architecture §0), `SummaryLlm` (+None/Ollama), `GraphStore`, `GraphService`, `GraphModels`.

- Sidecar `.svod/graph/` — **never touches `.svod/index`**. 12.2 MB = 1.79% of the 681 MB index.
- `graph: GraphSettings(enabled=false, summaryProvider="none")` — default OFF, mirrors RerankerSettings.
- **LLM only at build time.** Query time reads pre-computed summaries; the "works with no LLM at all"
  invariant survives.
- Ниво 1 = `context_pack(graphExpand=true)` → 1-hop neighbourhood into leftover budget, blocks marked
  `viaGraph`/`viaPath`.
- **Dropped mid-build:** the planned backlink tie-break in `IndexService` — it contradicted the
  stronger invariant that `search()` is provably unchanged.

## Local deployment (2026-08-17)

Live `dist/config.local.multivault.json` now has a `graph` block: `enabled: true`,
`summaryProvider: "ollama"`, `summaryModel: "qwen2.5:7b-instruct"` (pulled, 4.7 GB),
`rebuildOnStartup: false` (builds are explicit). Backup at `config.local.multivault.json.bak-20260817`.
The block is TOP-LEVEL so it applies to all three vaults (personal/work/lukanet).

Timing: graph itself 12–14 s; **with Ollama summaries the build is dominated by the LLM** — roughly
30–40 s per community on a 7B model, so ~21 communities ≈ 10–12 min. Model stays resident (~4.6 GB).

## Hard-won lessons

1. **`./gradlew installDist` writes into the LIVE engine's classpath.** Doing it while :7619 runs swaps
   the jar under a live JVM and breaks **lazy class loading** — `/api/v1/graph` started 500ing with
   `dev/svod/engine/api/GraphNodeDto`. Routes already exercised keep working, so the damage is invisible
   until a cold path is hit. Recovery: build in a `git worktree` elsewhere, copy the jar back,
   kickstart. **Never installDist from a feature branch while the daily driver is up.**
2. **Feature-detect on `apiVersion`, never on a 404.** The engine serves the web viewer as an SPA
   fallback, so an unknown path returns **200 text/html** and the Swift client raises a *decoding*
   error, not `.notFound`. Use `EngineModel.apiVersionAtLeast(major, minor)` like `supportsMemory`.
3. **Check an endpoint returns 200 before timing it.** An I1 latency figure was measured against
   `?query=` where the parameter is `q` — every request was a 400. Real number: 6–14 ms warm.
4. **Take test counts from `build/test-results/*.xml` after an exclusive run.** `grep -c ' FAILED'` on
   stdout matches `Task :test FAILED` and `BUILD FAILED`; a concurrent gradle in the same tree kills a
   run with "Could not write XML test results" and overwrites the report set.
5. **A test that passes with the fix removed is worse than no test.** The first cancellation test used
   `close()`, which interrupts and therefore exercises the catch path, not the early-return path it
   claimed to guard. Verify negative direction before trusting a guard.
6. Unit tests found none of the three quality defects; running against a **copy** of the real vault
   found all three (useless fallback labels, colliding labels, and the 404 feature-detection).

## Measured (copy of `personal`, 3,096 notes / 79,215 chunks / 681 MB index)

| | |
|---|---|
| Graph build (no summaries) | 12–14 s, `Thread.MIN_PRIORITY` |
| `search()` warm | 6–14 ms, HTTP 200, 10 hits — unaffected |
| `communities(query)` | 4–6 ms warm |
| Output | 14,315 edges (732 link / 13,583 sim), 643 communities / 3 levels |

Suite **308 tests / 306 passed / 0 failures / 2 skipped**, 37 new. CI green on the release tag with 37
graphrag test mentions in the log (i.e. actually collected — see `mem:kotlin-junit-silent-skip`).

## Known limitation

The coarsest level reaches communities of ~588 notes while the prompt fits fewer than ten. The prompt
states "these are N of M" so a summary cannot be silently fabricated, but properly summarising a group
that large needs **hierarchical summarisation**, which is NOT built. First place to look if Ниво 2
disappoints — before considering Ниво 3.

## Process note

The mandatory adversarial-verifier gate was spawned twice and **never returned a verdict** (three idle
notifications, zero findings). All verification in the PRs is first-party, run with real commands.

Related: `mem:svod-ui-architecture`, `mem:svod-engine-deploy-launchd`, `mem:svod-ui-release-signing`,
`mem:kotlin-junit-silent-skip`, `mem:wrong-subject-numbers`.
