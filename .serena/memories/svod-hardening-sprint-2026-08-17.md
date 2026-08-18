# Svod — hardening sprint (engine v1.18.0→v1.18.1 / contract 0.27.0, app v0.2.19)

Ran after the incremental-attachment release, from an internal survey of the LIVE engine
(`claudedocs/research_svod-improvements_2026-08-17.md`). The codebase had **zero `TODO`/`FIXME`
markers and zero open issues** — nothing here came from a bug report.

Engine PR #12 (merged `c0c8796`, tag `v1.18.0`), app PR #8 (merged `2ff4627`), recall PR #9
(merged `e50e6cb`, split out on review). Retro: `svod/retro/retro-2026-08-17-hardening.md`.

## Shipped

- **JSON 404 for unknown `/api` paths.** They returned **200 text/html** — the web viewer's SPA
  fallback swallowed the whole namespace, so a typed client raised a *decoding* error instead of
  not-found. That is why the house rule became "feature-detect on `apiVersion`, never on 404"; the
  rule stands, but the engine no longer forces it. Ktor scores explicit segments above the
  `route("/api/{...}")` tailcard, so nothing is shadowed (verified: WebSocket + contract-path tests
  pass with it live).
- **`GraphScheduler`** — v1.17.0's drift trade assumed a periodic rebuild that nothing performed.
  Two triggers, either sufficient: `graph.rebuildAfterAttached` (honest — a rebuild is minutes of
  local LLM) and `graph.rebuildIntervalMinutes` (safety net). Both unset ⇒ never starts.
  **Live config: 50 attached / 10080 min.**
- **`GraphStatus.driftRatio`** — share of attached notes whose placement vote no longer names their
  community, sampled ≤50 evenly, against the FINEST level. Two documented blind spots: compares votes
  not partitions, and a note whose neighbourhood thinned below threshold casts no vote (so drift by
  *losing* cohesion reads 0.0).
- **Hierarchical summaries behind `graph.hierarchicalSummaries` (off).** Counted: the coarsest level
  has 38 communities ≥3 (median 44, largest 320) and holds ALL the summaries; level 0 has **258**
  (median **7**, fits the prompt entirely) and had none. The flat path summarises where a summary is
  least trustworthy. Flag on ⇒ level 0 from raw excerpts, coarser levels from CHILD titles+summaries.
  38 → ~354 calls, so off by default.
- **App:** level picker (finer levels were API-reachable, UI-unreachable), `minSize ≥ 3` filter
  (546 communities at the coarsest level, only 38 usable), drift in the banner above 20%, and the
  **first 12 tests in the repo**.
- **`release.sh` publish order** — `gh release create` tags the remote HEAD, so creating the release
  before pushing the appcast commit tagged the WRONG commit. Commit+push first; publish retried;
  a genuine commit failure now exits instead of being swallowed by `|| true`.
- **`backupOnChange: true`** on `personal` (was up to 6 h of unbacked agent writes).

Suite: engine 336 → **357**, app 0 → **12**.

## The two lessons worth keeping

**1. Verify every new test in the NEGATIVE direction before opening the MR.** The adversarial gate
returned FAIL and found three tests that could not fail if their subject were reverted:
- the hierarchical "flag off ⇒ unchanged" test built twice with the flag OFF and compared the two —
  a determinism check of one path against itself;
- `start does nothing when unconfigured` slept 200 ms against a loop that delays ≥60 s first;
- worst, `a freshly attached note does not count as drifted` asserted `0.0` — which is also what a
  metric that never runs returns. **Behind it was a real defect:** `measureDrift` read the *pre-pass*
  `attachedPaths` and was structurally blind to everything the pass computing it had just attached.
  Fixed by passing the post-pass list; the test that pins it asserts exactly `0.5` (one drifted +
  one freshly attached), where the old code gives `1.0`.

Reverting each subject and re-running took four minutes for all three. Do it every time.
See [[wrong-subject-numbers]] — same family, and I had the note and still wrote it.

**2. Probe an unattended job's ENVIRONMENT before enabling it.** The recall distiller had written
0 notes from 9 sessions since v1.11.0. Enabling it exposed three blockers in sequence, each alone
enough to make it silently no-op:
- `claude` is not on launchd's PATH (no login shell; CLI under `$HOME`);
- **the agent cannot make any HTTP call** — global PreToolUse hooks route curl/WebFetch at the
  context-mode MCP server, which is NOT connected in a headless `claude -p` run. It reported "engine
  unreachable" while `/ready` answered 200;
- the work dir under `$TMPDIR` is outside the workspace, and a headless session cannot grant itself
  file access.

Plus a fourth once it ran: `noteRefs` is `List<String>`, so ONE manifest entry without a note 400s
the whole request (`rc=22`) and loses the batch. **Shape now: the SCRIPT does all HTTP; the agent
only reads local files (inside the project dir) and writes notes there; the script copies them into
the vault and POSTs the results.** Time-boxed at 30 min — one run hung for 27.

Measured after: 14 captured → **3 distilled, 4 notes, 107,094 → 6,918 bytes (15.5×), 5 proposals**,
one of which correctly diagnoses blocker 3 by itself.

## Cold start, finally broken down (the sprint added per-phase timings)

| phase | `personal` | `work` (2 notes) | `lukanet` (111) |
|---|---|---|---|
| engine open | 15,340 ms | 128 ms | 757 ms |
| index start | 1 ms | 2 ms | 3 ms |
| **file watcher start** | **34,491 ms** | **4,717 ms** | 1,172 ms |
| graph start | 2,380 ms | 9 ms | 33 ms |

The watcher is **66% of a ~52 s boot**. The tell is `work`: two notes, 4.7 s — so it is not
proportional to notes.

**FIXED next day in v1.18.1: ~52 s → 12.6–13.8 s.** And the obvious hypothesis was WRONG —
`DirectoryWatcher.build()` is **141 ms**; `watchAsync()` is what blocks. The cost is the default
**content** hasher reading every byte under the watched root (97 MB `.git` + 839 MB `.svod`), which
the listener then discards by path.

Measured A/B (warm, `watchAsync`) before choosing:

| | personal | lukanet | work |
|---|---|---|---|
| content hashing (was) | 6,395 ms | 393 ms | 810 ms |
| **`FileHasher.LAST_MODIFIED_TIME`** | **152 ms** | **16 ms** | ~1 ms |
| `fileHashing(false)` | 104 ms | 12 ms | 6 ms |
| watch children, skip `.git`/`.svod` | 657 ms | 11 ms | 1 ms |

**Took mtime hashing over the two FASTER options deliberately:** `fileHashing(false)` drops the
de-duplication that suppresses an event for a touched-but-unchanged file; watching hand-picked
children instead of the root silently stops watching new top-level entries (a correctness hole, not
a trade). The trade actually taken — (mtime, size) instead of content — is pinned by a
same-length-rewrite test.

`engine open` was `recover()` calling `commitAll` on **every** boot: jgit add/status stat every
tracked file, a cost this codebase had already documented and routed around for the write path
(`commitPaths`) but never for boot. Native `git status --porcelain` is **20 ms vs 15.3 s**, so it
gates the walk. Recovery is NOT narrowed — an offline edit is an uncommitted change, `status` sees
it, the commit still happens; any failure to answer falls through to the full path. Guarded by
`ColdStartTest` + the pre-existing `CrashRecoveryTest`, both of which fail if the skip is made
unconditional.

| phase (personal) | before | after |
|---|---|---|
| engine open | 15,340 ms | 1,044–1,375 ms |
| file watcher start | 34,491 ms | 1,748–2,568 ms |
| **/ready** | **~52 s** | **12.6–13.8 s** |

`graph start` (~2–3 s) is now the largest remaining phase. Suite 357 → **361**.

## Still open

- `work` and `lukanet` have **no backup remote** (`lukanet` holds 111 notes).
- Hierarchical build never run for real; do it when the machine is free and compare against today's 38.
- The cold-start fix above.

Related: [[svod-graphrag-incremental-attach]], [[svod-graphrag-tuning-and-ux]], [[svod-ui-release-signing]].
