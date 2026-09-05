# Retro — shared vault sprint 1 (2026-09-05, both repos)

Period: last 7 days. All activity landed on one day (2026-09-05, 10:30 → 15:33), one contributor.

## Numbers

| Metric | App (svod-ui-macos) | Engine (svod) |
|---|---|---|
| Commits on main | 14 (2 merge commits) | 2 (1 squash-merged PR #18) |
| LOC | +3,510 / −400 | +2,251 / −49 |
| Test LOC share of additions | 20.7% | 30.9% |
| Suite size | 30 → 53 tests | 409 → 439 tests (11 skipped) |
| PRs | #11 merged (no CI in this repo) | #18 merged, CI green in 4m27s |
| Sessions (<2h gaps) | 2, avg 51 min | 2 |
| Days with commits | 1 of 7 | 1 of 7 |

Hotspots (app): `MultiEngineClient.swift` ×4, `EditorView.swift` ×4, `AppModel/VaultModel/DTOs/LiveSvodClient/SvodClient` ×3 each. Expected for a sprint that threads one router through every layer; nothing above 4 changes.

Commit mix (app): 5 fix, 2 feat, 2 test, 1 release, 1 chore, 1 docs, 2 merges. Four of the five fixes are review/verifier findings on the same feature, made before release.

## Health

Velocity 6 · Tests 7 · Focus 9 · Hotspots 8 · PRs 9 → **8/10**

Velocity is bursty: seven days of nothing, then one 5-hour day that shipped two releases' worth of work. Test share on the app side (20.7%) is below the 25% target even after adding 23 tests; the engine side is above it.

## What the process caught (the part worth keeping)

1. **The adversarial verifier failed the engine PR on two real authorization bypasses** — `//api/v1/users` skipped authentication and `/api/v1/%75sers` skipped the admin table, because the interceptor matched the raw path while Ktor matches a normalised one. 433 green tests said nothing about it; the verifier proved it on a live engine. Fixed with canonical-path matching and a test that fails when the check is removed.
2. **The verifier failed the app PR on Settings → Updates**, which would have applied an engine update on the company's central engine when a company vault was selected. Every other lifecycle call was pinned to local; two were missed. Now tested.
3. **It then caught a flaky test I had just written around** — the merged-events test raced (3 failures in 8 runs). I had noticed the race and made only my new test tolerant of it, leaving the old one. The fix is in the mock (a stream that stays open), not in the assertion.
4. Code review (8 angles, 14 verified findings) found the leak of cross-vault backlinks and untagged events to readers of other vaults, the last-admin lockout, and `dist/secrets/` not being git-ignored while the live config lives in the repo.

## Insights

**Insight**: A green suite plus a live smoke test still missed two path-normalisation bypasses.
**Evidence**: 433/433 green before review; both bypasses reproduced on the running engine by the verifier.
**Recommendation**: Keep the verifier gate mandatory for anything under `api/`; add the canonical-path rule to the engine's security notes so the next path-based check starts from the normalised path.

**Insight**: Fixing only the test you are writing, when the same race is in the neighbouring test, ships the flake.
**Evidence**: `testUntaggedLocalEventsAreTaggedWithTheLocalDefault` was made tolerant; `testEventsAreMergedAndRemoteOnesRekeyed` failed 3/8 an hour later.
**Recommendation**: When a race is found in a mock, fix the mock, then grep for every test on that mock.

**Insight**: App test share stays under target while the engine is over it.
**Evidence**: 20.7% vs 30.9% of added lines; 23 app tests added, all model/router level, no view test.
**Recommendation**: Next app feature adds at least one test per new Settings model before the view is written.

**Insight**: Shipping happens in one-day bursts.
**Evidence**: 1 of 7 days with commits in both repos; 16 commits in five hours.
**Recommendation**: Fine for a solo project, but keep every burst ending with a merge and a deploy (as this one did) — a burst that ends on a branch is where drift starts.

## Action items

1. Tag engine `v1.20.0` and release app 0.2.23 (build 25) — both are on main and deployed/merged but unreleased; the self-updater and Sparkle see neither until tagged.
2. Sprint 2 planning from `docs/requirements-shared-vault.md` §deferred: a real central engine host, SocialScore → org repo, replica/offline mode.
3. Engine follow-ups from review: `/health|/ready|/metrics` open off loopback (decide at deployment), `GET /settings`/`/sync/config`/`/sources` show server paths to READERs, duplicated helpers.
4. App follow-ups: profile removed mid-autosave, reconnect tearing down every remote socket, `MockSvodClient.mockUsers` static state, bound the wait in the merged-events test.
