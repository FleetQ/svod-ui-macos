# Design — Update system (engine + macOS app)

**Date:** 2026-06-29 · **Branch:** `feat/auto-update` (UI) + engine `main`

## Problem
Neither side has a real update path. Engine: `ApiCompatibility` gate + a *skeleton*
`self-update.sh` (stale port, fictional install path), `SelfUpdate` not wired to any
route. UI: no Sparkle, no check, just shows the bundle version. Updating = manual
rebuild/installDist + restart, or hand-download a release. We now have GitHub Releases
for both (engine v1.7.0 app-images; UI v0.1.0) — the natural update source.

## Forcing questions
- **Who / today?** The owner running the app + engine locally. Today they have no
  signal a new version shipped and must update by hand.
- **MVP?** (a) Engine tells the UI "a newer *compatible* engine exists" and applies it
  on one confirmed click. (b) The app updates itself via Sparkle from the GitHub
  appcast.
- **Whoa?** One banner → one click → engine downloads, verifies, swaps, restarts, the
  app reconnects. App self-updates like any mature Mac app.
- **Compounds?** Every future release reaches users without manual steps; the
  `ApiCompatibility` gate keeps an engine update from breaking the client contract.

## Decisions (validated with user)
1. **Engine = notify + one-button apply.** `GET /api/v1/update/check` (GitHub
   latest-release + `ApiCompatibility` semver gate) and `POST /api/v1/update/apply`
   (gated; spawns the finished `self-update.sh`: download→verify→swap→`launchctl`
   restart). User confirms before the swap. *Delegated to the engine agent.*
2. **UI = Sparkle (appcast).** Standard macOS auto-update; appcast feed from GitHub
   Releases; in-app "Check for Updates…" + automatic checks.
3. **UI also surfaces the engine's update status** (re-uses the engine endpoints) so
   one screen covers both — the "UI manages engine update" option, layered on Sparkle.

## Validation boundary (HARD — surfaced, not assumed)
Sparkle's actual download/install path **cannot be validated in this environment**:
- The Xcode project has **no `DEVELOPMENT_TEAM`** (CODE_SIGN_STYLE Automatic, hardened
  runtime on) → no Developer ID. Sparkle requires a **signed + notarized** app and a
  **signed update** (EdDSA) for Gatekeeper to accept the install.
- Therefore this sprint delivers: Sparkle wired in + **building green**, the updater
  initializing, the "Check for Updates" UI, the appcast feed URL, a generated EdDSA
  **public** key in Info.plist, and a release CI that produces the signed zip +
  `appcast.xml` **when signing secrets are present** (non-fatal/unsigned otherwise,
  mirroring the engine release's best-effort pattern).
- **Requires the user to finish:** add an Apple **Developer ID** + notarization creds
  + the Sparkle **EdDSA private key** as GitHub Actions secrets, then cut a signed
  release. Until then the app builds and "Check for Updates" runs but cannot install.
  The engine `/update/check` path IS fully validatable live.

## Out of scope
- Silent/auto-apply engine swaps without confirmation.
- In-app code signing or notarization (infra/credentials, not code).
- Delta updates.
