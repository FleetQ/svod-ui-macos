# OpenViking borrow sprint (2026-09-15) — engine v1.22.0 / contract 0.32.0, patch v1.22.1

Research: `claudedocs/research_openviking_2026-09-15.md` (mem `svod-openviking-borrowed-ideas-research`).
Design/plan/test-plan docs live in the engine repo: `docs/{design,architecture,test-plan}-openviking-borrow.md`.

## What shipped (engine PR FleetQ/svod-engine#20, squash 8a239f3, tag v1.22.0)
- **Capture bug fixed.** `POST /memory/capture` used to keep the FIRST capture of a sessionId and dedupe
  every later one, and the hook ran only on `Stop` → every stored session was its first response
  (8 live sessions, 965 B – 5.8 KB). Now: a strictly LARGER transcript (UTF-8 bytes) rewrites the same
  note (`updated: true`, earliest startedAt kept, project kept); equal/shorter → `deduped`. Size and
  revision come from ONE read (gate caught a two-read race; concurrency test 10 rounds × 8 async).
  A distilled session that grows is undistilled again.
- **App hook** (svod-ui-macos PR #13, merge 8837617): `.claude/hooks/capture-session.sh` on Stop,
  PreCompact, SessionEnd. Stop posts first time then only at 2× growth (each accepted capture is a git
  commit of the whole transcript); PreCompact/SessionEnd always post. Excludes `isCompactSummary`.
  Body built with `jq -cs ... "$tpath"` + `utf8bytelength` — `--arg` fails over ARG_MAX (~1 MB) and
  `jq -R` split multibyte UTF-8 at read-buffer boundaries (85 Cyrillic chars corrupted in 1.4 MB).
  Harness `hook_harness.py` 17 checks (old hook 5/15).
- **MCP `tree` and `grep`** (20 tools now). grep: literal/regex/ignoreCase, limit ≤500, never reads
  `messy/sessions/`, `messy/` only when recall includes it or prefix is `messy/`, skips `private: true`,
  masks `<private>` keeping line numbers. 2 s budget enforced inside matching via `DeadlineCharSequence`
  (JDK 20 optimizes `(a+)+$`; `^(a+)+\1$` is the real catastrophic case). `(a|b)*c` on long lines throws
  StackOverflowError → counted as `unsearchableLines`.
- **Unclosed `<private>` now fails closed** (hides to end of text) in index, context_pack, graph, grep.
- **Dropped: auto-recall injection** (OpenViking-style) — not built; see research doc for why.

## v1.22.1 — grep timed out live (found only by deploying), PR FleetQ/svod-engine#21
Squash `f6aa0e6` (tree = branch head 2446d6c), tagged `v1.22.1` on `f6aa0e6`; release run success, 6 assets, not draft,
live `update/check` current = latest = 1.22.1. Live engine runs a jar built
from 29ccc6c (later commits: CHANGELOG + one comment only). Squash merge answered HTTP 502 but had merged.
Gate: 4 rounds (R1 PASS wording, R2 FAIL changelog overclaims, R3 FAIL `\z` deadline row + "3 runs" that
were UP-TO-DATE, R4 FAIL "first minute" not measured → PASS). Wording gates caught what tests cannot.
v1.22.0 grep on `personal` (3,217 notes, 46.8 M chars, one 22.4 MB note `projects/skb2/docs/repo-context.md`)
timed out in 3 of 6 calls. A test-JVM probe of each step summed to ~0.45 s and did NOT explain it.
1. JFR on the live engine: 59/95 grep samples in `maskPrivateSpans` → `Character.toLowerCase`.
   **Kotlin `Regex` with IGNORE_CASE adds UNICODE_CASE.** Fix bf30101: `hasPrivateTag` pre-check with
   `regionMatches(ignoreCase=true)` (accepts exactly what the regex accepts; gate brute-forced every code
   point). 300 ms → 8 ms. Did NOT stop live timeouts on its own.
2. `lines()` allocated 372 MB per whole-vault call. Fix 29ccc6c: one `Matcher` per note over
   `DeadlineCharSequence(text)`, `matcher.region(start, end).find()` per line; default anchoring + opaque
   bounds = identical to per-line Strings (gate fuzz 902,048 comparisons, 0 diffs; `lines()` splits only
   CRLF/LF/CR). Allocation → <1 MB. Side effect: the deadline now also fires across short lines (old code
   made a fresh read counter per line, so lines < 4,096 reads never checked the clock).
3. **Known limit:** the first 3 whole-vault grep calls right after a restart still time out (uptime 37 s at the first call; the three took 34 s)
   (measured with 7.4/8.2 GB swap used, mediaanalysisd 106% CPU); later calls 1.4–2.8 s. Engine RSS was
   seen at 33 MB with a 1.35 GB used heap — heap compressed/swapped; swap-ins stayed low (40), so paging
   is NOT proven as the cause. Timed-out calls return partial hits.
- JFR sample counts on this Mac are sparse (41 samples over 18 s); use ratios, not absolute CPU.
- `PrincipalAuthTest` (audit order) and `OnnxRerankerTest` (4,299 ms > 4,000 ms ceiling) failed once in a
  gate run while a deploy build compiled on the same box; both pass alone. Load-sensitive, not grep.

## Gotchas learned
- `/usr/local/bin/git` is x86 → arm64 JVM / gh fail with `error=86 Bad CPU type`. Use `/usr/bin/git`,
  PATH `/opt/homebrew/bin:/usr/bin` (there is no `/opt/homebrew/bin/git`).
- context-mode hook blocks gradle in Bash → start via ctx_execute nohup + Bash until-loop.
- `git add -A` in the engine picked up `engine/.kotlin/sessions/*.salive` → `.kotlin/` now ignored.
- Squash merge of PR #20 returned HTTP 500 repeatedly with nothing wrong; a retry 60 s later worked.
- Release workflow `fail_on_unmatched_files: false` → always enumerate the 6 assets.
- Transcripts keep pre-compaction turns; count compactions by `compact_boundary`, not summary entries.
- `du` in this shell is aliased to `dust`; use `/usr/bin/du`. `top` is also aliased; use `/usr/bin/top`.
- Gradle re-runs of an unchanged test task are UP-TO-DATE: "passed 3 times" needs `cleanTest` or `--rerun`.
