# Retro — shared vault hardening, sprint 2a (2026-09-05, both repos)

Period: last 7 days. Everything is one day (2026-09-05); sprint 1 (morning) and sprint 2a
(afternoon) share it. Numbers are cumulative for the day on `main`.

## Numbers

| Metric | App (svod-ui-macos) | Engine (svod) |
|---|---|---|
| Commits on main (7d) | 21 (3 merges) | 6 (2 squash-merged PRs: #18, #19) |
| LOC (7d) | +3,853 / −510 | +3,533 / −86 |
| Test share of additions | 21.5% | 30.4% |
| Suite | 30 → 53 → **61** | 409 → 439 → **454** (11 skipped) |
| PRs today | #11, #12 merged | #18, #19 merged, CI green both |
| Sessions (<2h gaps) | 2 | 2 |

Hotspots (app): `MultiEngineClient.swift` ×7, its tests ×6, `MembersSettingsView` ×5, `DTOs` ×5,
`MockSvodClient` ×5. One file carried both sprints' routing logic; expected, but it is now the
place a third sprint should not keep growing.

Commit mix (app, 7d): 7 fix, 3 feat, 3 test, 2 release, 2 docs, 1 chore, 3 merges. Five of the
seven fixes are verifier or review findings on the same day's feature.

## Health

Velocity 6 · Tests 7 · Focus 9 · Hotspots 7 · PRs 9 → **8/10**

## What sprint 2a was

The security review of sprint 1 (`docs/security-shared-vault.md`) produced nine findings; the
sprint closed seven, two partially (`expiresAt` and the open `/health`/`/ready`), on engine
1.21.0 / contract 0.31.0 and app 0.2.24.

## What the process caught, in the order it caught it

1. **Code review (8 angles × 2 repos)** found that the first cut of "hide server paths" skipped
   `/sync/config`, that `/metrics` accepted any key (a reader could list every vault id the new
   404 rule hides), and — the one that mattered most — that the Host allowlist does not stop a
   **cross-origin WebSocket**: the browser sends a legitimate loopback Host and no CORS applies.
   The fix is an `Origin` rule, which the security review itself had not thought of.
2. **Verifier round 1 (engine)** failed on the sibling `mcp/AuditLog` still being 0644 on all
   four real vaults, and on the Origin rule ignoring the port (a dev server on :9999 was "us").
3. **Verifier round 2** failed on a 415 audited as 500 and on the 0644 fix having no test —
   reverting it left 452 tests green.
4. **Verifier (app)** passed first time, then found two small things (the last-seen gate keyed
   on data presence rather than `apiVersion`; a set never cleared) and one coverage gap.

Three rounds on the engine, each one narrower than the last. None of it was visible to a green
suite: every finding needed either a live engine or a reverted line.

## Insights

**Insight**: "Fix the pattern everywhere" was applied inside the file being edited (mock statics)
only after review pointed at it, and the 0644 sibling was found by the verifier's sweep, not by
me.
**Evidence**: `MockSvodClient` had five more statics after the users fix; four real
`audit.log` files were 0644 while the new audit file was 0600.
**Recommendation**: before committing a "make X owner-only / instance-scoped" change, grep the
repo for the pattern and list every site in the commit message, as CLAUDE.md already asks.

**Insight**: A security fix without a mutation-verified test is not closed.
**Evidence**: the 0644 fix, the `insecure` intersection and the earlier audit hook each survived
deletion with the suite green until a test was added.
**Recommendation**: the negative-verification loop stays mandatory, and it must include the
sibling fixes, not only the headline ones.

**Insight**: The threat model in a review is only as good as the mechanisms it names.
**Evidence**: the review said "no CORS → the browser cannot read responses"; that is true for
fetch and false for WebSocket. A reviewer angle ("altitude") caught it, the author did not.
**Recommendation**: for any localhost-API change, check the three browser channels explicitly:
fetch (CORS), WebSocket (Origin only), navigation/form (no preflight).

**Insight**: Test share on the app stays at ~21% while the engine holds 30%.
**Evidence**: 21.5% vs 30.4% of added lines over the day; app views remain untested by design.
**Recommendation**: keep pulling logic out of views into models (as `EngineAddress` and
`MembersModel.lastSeen` did) so the share can move without UI tests.

## Action items

1. Tag engine `v1.21.0` and release app 0.2.24 (both on main, deployed/merged, unreleased).
2. The four real `audit.log` files turn 0600 only when an agent writes after 1.21.0 is running;
   check `ls -l ~/svod/*/.svod/audit/audit.log` in a few days, or touch them once.
3. Sprint 2b (offline replica, SSO) from `requirements-shared-vault.md`; `expiresAt` for keys.
4. `MultiEngineClient.swift` is at 7 changes in a day — before sprint 2b, split the routing table
   from the event merging.
