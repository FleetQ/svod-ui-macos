# Svod — incremental attachment + actionable staleness (engine v1.17.0 / contract 0.26.0, app v0.2.18)

Closes the two items left open by `mem:svod-graphrag-tuning-and-ux` ("new notes are NOT in the
thematic map", options 1+3). Engine PR #11 (merged `feee3f4`, tag `v1.17.0`), app PR #7
(merged `7d4c897`, release commit `96432c1`, tag `v0.2.18` → same commit, no drift).

## What was built

`graph.incremental` (**off by default**). On every `IndexService.onSynced` — the hook the index
already fires after catching up to a commit — notes that appeared since the last full build are
placed into the communities that already exist:

- vector comes from `IndexService.noteVector` (mean-pooled stored chunk vectors) — **zero embedder
  calls, zero LLM calls**;
- k nearest already-placed notes vote, **weighted by cosine**; the note joins the dominant community
  **at every level** (each level is a partition — placing it only at the coarsest still leaves it
  missing from `level=0`);
- **Louvain is not re-run, summaries are not regenerated.** `Community.addedSinceSummary` discloses
  the growth instead;
- persists via `GraphStore.saveIncremental` — only `communities.json` + `meta.json`, never the 12 MB
  `graph.json`. `GraphMeta.attachedPaths` is the record of what is already placed (attached notes are
  deliberately NOT added to `NoteGraph.nodes`), defaulted so old sidecars still load — **no
  SIDECAR_VERSION bump**, which would have invalidated the operator's 15-minute build.

Status gains `incremental`, `attachedCount`, `pendingCount` (+ `GraphCommunity.addedSinceSummary`).
Counts are computed on the attach thread and only *read* by `status()`: enumerating indexed paths is
`pathBlobMap()`, a full stored-field sweep over 79k docs, and it must never land on a request path.

## The finding that changed the design — measure, don't reason

The first cut reused the build's `simThreshold` for attachment, with a comment arguing that "a note
that would not have earned an edge must not earn a community". It compiled, 15 tests passed, and it
was **wrong in production**: at the tuned `simThreshold: 0.88` the real pending note stayed
`pending: 1, attached: 0`. Attachment had inherited exactly the **17% of notes a 0.88 build leaves
uncovered** — the opposite of what the feature exists for.

Bisected live by kickstarting the engine at successive thresholds:

| attachThreshold | 0.88 | 0.80 | 0.75 | 0.70 | 0.60 |
|---|---|---|---|---|---|
| result | pending | pending | **attached** | attached | attached |

Nearest neighbour ∈ **[0.70, 0.80)**. Fix: `graph.attachThreshold`, defaulting to `simThreshold`.
**The two thresholds answer different questions** — `simThreshold` decides whether an edge is worth
CLUSTERING on (a weak edge may not survive modularity optimisation anyway); attachment is
classification against a partition that already exists and changes no community.

Live setting **0.75** — the sweep's measured 95%-coverage point, not a guess.

Where the note landed at production settings (`simThreshold 0.88`, `attachThreshold 0.75`):

```
level 0 | L0-227 "projects/agent-fleet/docs/research/research_anthropic-claude-p-billing-change…" size=4  +1
level 1 | L1-1   "projects/harbormaster/docs/legacy, research…"                                  size=169 +1
level 2 | L2-2   "Local FleetQ Development Notes"                                                size=253 +1
```

Level 0 put it with the four agent-fleet notes on Claude billing/CLI pooling — the same notes
semantic search returns for it independently. Coarser levels roll up, as expected.

## The pane

The badge "остаряло" is now the **fallback**, shown only when the engine cannot count (older than
0.26.0, or incremental off). When it can: "N нови бележки след строежа", "M от тях още не са в никоя
тема" (only the pending half is a reason to rebuild *now* — attached notes ARE findable), and an
inline "Построй наново". Rows show `+N` for `addedSinceSummary`.

`GraphStatus.newSinceBuild` is **nil, not 0**, when unreported — nil falls back to the badge, 0 is a
positive "nothing is missing" and hides the banner. All new DTO fields are Optional, so decoding
against an older engine cannot fail.

`MockSvodClient.graphStatus()` now returns **stale WITH counts**. It used to be never-stale, which is
how the useless badge survived this long unexamined — a mock that only renders the happy path hides
the state the UI exists for.

## Live config (`dist/config.local.multivault.json`, backup `.bak-20260817-attach`)

`graph.incremental: true`, `graph.attachThreshold: 0.75`, everything else unchanged
(`simThreshold 0.88`, `simEdgesPerNote 5`, ollama/qwen2.5:7b-instruct, `rebuildOnStartup false`).

## Accepted drift (unchanged, restated)

Attachment does not recompute the partition. Between builds it keeps notes *reachable*; the periodic
full rebuild restores the truth. Not a defect — but the reason the count in the pane matters.

## Process notes

- Built and tested in a **git worktree** (`/Users/katsarov/htdocs/svod-wt-attach`), never
  `installDist` from the main checkout while :7619 was live. Deployed by `rsync -a --delete` of
  `build/install/svod-engine/lib/` into the live path + kickstart — `--delete` matters, or the old
  `svod-engine-1.16.0.jar` stays on the classpath next to the new one.
- Test counts from `build/test-results/*.xml` after an exclusive run: **336 / 0 failures / 2 skipped**
  (was 319). 17 new.
- Both new guards verified in the **negative** direction: removing the member-dedup filter fails the
  crash-window test; removing the threshold check fails both threshold tests.
- `Scripts/release.sh PUBLISH=1` **aborted** on `gh release create` during a GitHub-wide 503 storm —
  its `2>/dev/null || gh release upload` fallback then failed with "release not found" and `set -e`
  killed the script *before* the appcast commit. Recovered manually in the RIGHT order: commit+push
  the appcast first, THEN `gh release create` (so the tag lands on the release commit — the script's
  own order is what causes the known tag drift).
- The engine release workflow failed once on 429/502/503 while downloading actions (GitHub outage,
  not our code) — `gh run rerun --failed` was the fix.

Related: `mem:svod-graphrag-tuning-and-ux`, `mem:svod-graphrag-levels-1-2`,
`mem:svod-graphrag-summary-quality`, `mem:svod-engine-deploy-launchd`, `mem:svod-ui-release-signing`.
