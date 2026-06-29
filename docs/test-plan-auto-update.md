# Test Plan — Update system

**Date:** 2026-06-29

## Engine (delegated — `UpdateServiceTest.kt` + live :7619)
| # | Case | Expect |
|---|------|--------|
| E1 | fake release: newer same-major | check → updateAvailable=true, compatible=true, asset surfaced |
| E2 | fake release: same version | updateAvailable=false |
| E3 | fake release: newer MAJOR | updateAvailable=true, compatible=false |
| E4 | release fetch returns null / network fail | updateAvailable=false, **no throw**, 200 + notes |
| E5 | apply() when !updateAvailable or !compatible | NotApplicable → 409 |
| E6 | apply() with no updater script | NotSupported → 501 |
| E7 | LIVE GET /update/check on :7619 | 200; currentVersion 1.7.0; latest v1.7.0 ⇒ updateAvailable=false, compatible=true (no spurious update) |
| E8 | LIVE POST /update/apply | **NOT triggered** (disruptive); gate covered by E5/E6 |

## UI
| # | Case | Expect |
|---|------|--------|
| U1 | `xcodebuild` Debug with Sparkle linked | **green**, Sparkle resolves |
| U2 | Updater initializes | `SPUStandardUpdaterController` constructs without crash; "Check for Updates…" menu present |
| U3 | Updates settings panel (Mock) | App card shows version + auto-check toggle; Engine card shows "up to date" |
| U4 | Engine update banner (Mock newer) | shows latest version + "Update engine" button |
| U5 | Old engine (Mock `.notImplemented`) | engine card → "needs a newer Svod engine" |
| U6 | Info.plist keys present in built app | SUFeedURL + SUPublicEDKey + SUEnableAutomaticChecks injected |

## Validation boundary (cannot pass here — documented, not faked)
- **U-SIGN**: actual Sparkle download+install requires a Developer ID-signed +
  notarized app and an EdDSA-signed appcast. No `DEVELOPMENT_TEAM` configured →
  **not validatable** until the user adds signing/notarization secrets + cuts a signed
  release. We validate up to "build green + updater initializes + feed URL set".

## Acceptance
- Engine E1–E7 pass; E8 intentionally skipped (gate proven by unit tests).
- UI U1–U6 pass locally.
- Honest report of U-SIGN as the remaining manual prerequisite.
