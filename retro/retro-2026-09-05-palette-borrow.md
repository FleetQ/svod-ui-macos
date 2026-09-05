# Retro — 2026-08-29 → 2026-09-05 (Palette borrow sprint)

**4 commits | 1 contributor | +1,515 / −293 LOC (of which 132/132 is the regenerated editor bundle) | 1 merge (local `--no-ff`, no PR)**

All activity is one day, 2026-09-05: research report in the morning, `/sprint-orchestrate full` afterwards. The previous seven days had no commits (last one: the v0.2.21 release on 08-28).

## What shipped

| Commit | What |
|---|---|
| `ffcfd01` feat | review inbox, HTML preview, pinned notes, 16 tests |
| `1fa34d5` fix(review) | 10 confirmed code-review findings, incl. the iframe→bridge hole |
| `63d6670` fix(revert) | vault pinned into every revert request (verifier FAIL → PASS) |
| `d6cd860` merge | main, pushed; **no release cut** |

## Metrics

| Metric | Value |
|---|---|
| Source LOC (excl. bundle) | +1,383 / −161 |
| Test LOC | +339 / −11 → **24.5%** of source additions |
| Test cases | 12 → **30** |
| Coding session | one, ~09:40–11:10 (commits 10:30–11:08) |
| Hotspots | `ActivityModel.swift`, `ActivityReviewTests.swift`, both design docs — 3 touches each; no file above 3 |
| Review → fix loops | 2 (code review with 10 verifiers; adversarial gate failed once on a real race) |

## Health

| Velocity | Tests | Focus | Hotspots | PRs |
|---|---|---|---|---|
| 6 — one dense day after a quiet week | 7 — 24.5%, just under the 25% bar | 9 — one feature branch, one theme | 9 — max 3 changes per file | 8 — merged within the hour, no PR by policy |

**Overall: 8/10.**

## Insights

**Insight:** Both real defects were found by *reproduction*, not by reading.
**Evidence:** the iframe→bridge hole ("cannot reach the Swift bridge" was in my own comment and design doc) fell to a WKWebView harness; the vault race ("re-check after every await") fell to a repro that wrote vault A into vault B. Reading the code produced both wrong claims.
**Recommendation:** any claim about isolation or ordering gets a harness before it gets a sentence in a doc. Keep the two harness recipes (`scratchpad/wktest/main.swift` shape; Nexion web pane + `SvodEditor` probe) in the Serena memory, which they now are.

**Insight:** The review's reuse pass paid for itself; the correctness pass paid for the sprint.
**Evidence:** 4 reuse findings folded (ActivityRow, `fileName`, `TreeNode.filePaths`); 10 correctness findings, of which 2 would have been user-visible data loss (promote revert trashing a note, cross-vault write).
**Recommendation:** keep `/code-review high` + the adversarial gate as the fixed ship sequence; do not skip the gate on "small" app-only sprints — this one was app-only.

**Insight:** Test share sits at 24.5% and the new tests are non-vacuous, but the JS side has zero automated coverage.
**Evidence:** 10 mutation runs made exactly the matching Swift tests fail; the HTML preview was verified only through a browser harness driven by hand, and the first two rounds chased a harness artifact (calls before `boot()`).
**Recommendation:** turn the http harness into `tooling/webeditor/test/harness.html` with a `#results` contract, so the next JS change runs it in one command instead of re-deriving it.

**Insight:** Nothing in this sprint was looked at in the running app.
**Evidence:** no screenshots or GUI checks; ReviewCard layout, toolbar badge clipping in a macOS toolbar, and the iframe inside WKWebView are unverified visually.
**Recommendation:** a separate short session: run the Debug build, open an `.html` note, pin a note, trigger an agent write over MCP, revert it. Then cut v0.2.22.

## Action items

1. Visual pass in a fresh session, then release v0.2.22 (build 24) — main is ahead of the installed app.
2. Engine follow-up: tag MCP `agent.activity` / `commit.created` with `vault` in `SvodTools.outcomeResult`, so cross-vault inbox rows open the right note. Small, contract-additive.
3. Commit the JS harness under `tooling/webeditor/test/` so HTML-preview regressions are one command away.
