# Svod graph — tuning the community structure, and what the Теми pane is for (2026-08-17)

Third follow-up, after `mem:svod-graphrag-levels-1-2` and `mem:svod-graphrag-summary-quality`.
Closes the two things those left open: communities too coarse, and a UI pane that listed themes
beautifully and then led nowhere.

## simThreshold: measured, not guessed

Swept on a COPY of `personal` (3,096 notes) with summaries OFF, so each build was ~12 s and the sweep
measured STRUCTURE only — which is what the threshold actually controls.

| threshold | k | edges | themes (≥3) | largest | median | notes covered |
|---|---|---|---|---|---|---|
| 0.75 | 6 | 14,315 | 21 | 588 | 106 | 2,953 (95%) |
| 0.82 | 6 | 13,514 | 22 | 582 | 74 | 2,846 (92%) |
| **0.88** | **5** | **8,664** | **38** | **320** | **38** | **2,568 (83%)** |
| 0.92 | 4 | 3,709 | 75 | 156 | 6 | 1,706 (55%) |

**Chose 0.88 / k=5.** Nearly doubles the theme count, halves the largest community, and drops the
median from 106 to 38 — a group small enough that a summary can actually characterise it. The cost is
coverage: notes that no longer attach to any theme fall below `minCommunitySize`. At 0.92 that cost
reaches 45% of the vault, which is too much to pay for finer clusters.

**The trade to remember:** threshold up ⇒ more, sharper themes, fewer notes on the map. There is no
setting that gives both.

Build time scales with theme count when summaries are on (~20-40 s per community), so 0.88 roughly
doubles it versus 0.75.

## What the Теми pane is for

The pane listed themes readably and then had two dead ends, one actively misleading:

1. A wall of hundreds of member paths truncated from the LEFT — unreadable.
2. The canvas scoped to the theme's members, which showed almost nothing.

Cause of (2), and worth remembering because it will recur: **the canvas draws the WIKILINK graph,
while themes are formed mostly from SIMILARITY edges.** Measured — the 300-note "Documentation and
Policies" theme had **zero** wikilink edges among its members; "Boruna Integration" zero; Harbormaster
one. Filtering the right notes through the wrong graph is guaranteed to look broken.

**Resolution:** selecting a theme now filters the **sidebar notes tree** to its members (banner names
it, counts it, clears it; the text filter still applies on top). The canvas is decoupled. The pane is
the map; the tree is where you walk.

Rejected alternative: exposing the derived (link+sim) edges so the canvas could draw the real theme
structure. It is the more complete answer but costs another contract bump and release cycle, and the
value the operator asked for was navigation — "show me these notes so I can open them" — not a prettier
visualisation. Revisit only if the canvas becomes the thing people want to look at.

## Agent ergonomics (contract 0.25.0, engine v1.16.0)

One default `graph_communities` call returned **≈44,300 tokens, 97% member paths**, ~1,200 tokens of
actual signal. Fixed by shape, not by prompt: the listing previews 5 paths (`sampleMembers` +
`moreMembers`, `size` still true) and `graph_community(id)` returns one theme's full membership.
`GraphService.community(id)` had existed since the first sprint but was **never exposed** — that dead
accessor was the whole reason the bulk call had to carry everything.

App API keeps `members=full` as its default for app v0.2.16 back-compat; `sample` / `none` are opt-in.
Measured after: 44,328 → 2,405 (`sample`) → 1,255 (`none`) tokens.

Tool descriptions now carry the guidance: when to prefer this over `search`, what `level` means
(0 = finest, ranks a specific query better), that `NOT_BUILT` ≠ "no themes", that `stale` is usable.

## New notes are NOT in the thematic map — measured, and the decided fix

**The index is incremental; the graph is not.** Verified live on `personal` against a real note
written after the build (`memory/policy/808566111605.md`):

| | |
|---|---|
| search / index | finds it within seconds (incremental reconcile) |
| thematic map | **absent from every community at every level** |
| status | `stale: true`, `head` != `currentHead` |

Nothing auto-rebuilds: `rebuildOnStartup: false`, no timer, no commit hook. The only triggers are
the pane's refresh button and `POST /api/v1/graph/rebuild` — and a full rebuild is **~15 min for
personal**, almost entirely the 38 Ollama summary calls.

So the honest statement: the thematic layer describes the vault **as of the last build**, not as of
now. This is design §8's staleness trade, now with a number on it.

**Decided approach (agreed with the operator, NOT yet built) — options 1 + 3:**

1. **Incremental attachment, no LLM.** For a new/changed note: take its vector (already in Lucene
   after indexing — `IndexService.noteVector` needs no embedder call), find its k nearest existing
   note vectors, attach it to the community that dominates among those neighbours. No Louvain re-run,
   and **the community's summary is not touched** — one note among 320 does not invalidate it. Mark
   the community "grown since its summary" (additive field). Hook where the index already reacts to a
   commit.
3. **Actionable staleness in the pane.** Today it shows only a badge; it should say how many notes
   arrived since the last full build and offer a rebuild. May need a count field on
   `/api/v1/graph/status`.

**Accepted drift:** neighbour-attachment does not recompute communities, so after many new notes the
structure diverges from what a full Louvain would produce. That is why (1) and (2 — periodic full
rebuild) belong together: incremental keeps notes reachable, the periodic build restores the truth.
Not a defect; a stated trade.

## Live config

`dist/config.local.multivault.json` → `graph.simThreshold: 0.88`, `simEdgesPerNote: 5`,
`summaryProvider: "ollama"`, `summaryModel: "qwen2.5:7b-instruct"`, `rebuildOnStartup: false`.
Top-level, so it covers personal/work/lukanet. Backup: `.bak-20260817`.
