# Architecture — Update system

**Date:** 2026-06-29 · Engine contract 0.17.0 → **0.18.0**

## Engine (delegated — FleetQ/svod-engine, `main`)
- `GET /api/v1/update/check` → `UpdateCheckDto { currentVersion, currentContract,
  latestVersion?, updateAvailable, compatible, assetName?, assetUrl?, sha256?, notes?,
  publishedAt? }`. Queries GitHub `releases/latest`; `updateAvailable` = latest
  app-version > current (semver); `compatible` = same MAJOR (via `ApiCompatibility`).
  A failed GitHub fetch → 200 with `updateAvailable=false` + `notes` (never 500).
- `POST /api/v1/update/apply` → 202 `UpdateApplyDto { started, candidateVersion? }`;
  refuses 409 if no update / incompatible, 501 if no updater configured. Spawns the
  detached `dist/self-update.sh` (download→sha256→compat preflight→atomic swap→
  `launchctl kickstart`). Engine never swaps itself in-process.
- `UpdateService` is injected with a `releaseFetcher` so tests stay offline.
- Live-validatable: `/update/check` (against real GitHub). `apply` NOT live-triggered
  (disruptive) — covered by unit tests + the gate.

## UI (this repo)

### Sparkle integration
- **SPM dependency** `https://github.com/sparkle-project/Sparkle` (2.x) — the project's
  FIRST package dep, so `project.pbxproj` gains: an `XCRemoteSwiftPackageReference`, an
  `XCSwiftPackageProductDependency` (product `Sparkle`), `packageReferences` on the
  PBXProject, `packageProductDependencies` on the app target, and a
  `PBXFrameworksBuildPhase` linking Sparkle. Hand-edited carefully, then `xcodebuild
  -resolvePackageDependencies` + a full build to validate. (Synchronized root group is
  unaffected — that's only source-file membership.)
- `App/Updater.swift`: `final class Updater` wrapping `SPUStandardUpdaterController`
  (`startingUpdater: true`, no UI delegate needed for the standard flow). Exposes
  `checkForUpdates()` and `automaticallyChecksForUpdates` (bridged to the toggle).
- `SvodApp`: hold the controller; add a `CommandGroup(after: .appInfo)` "Check for
  Updates…" menu item bound to `updater.checkForUpdates()`.
- Info.plist via build settings: `INFOPLIST_KEY_SUFeedURL =
  https://github.com/FleetQ/svod-ui-macos/releases/latest/download/appcast.xml`,
  `INFOPLIST_KEY_SUPublicEDKey = <generated>`, `INFOPLIST_KEY_SUEnableAutomaticChecks =
  YES`. `SUFeedURL` points at a `latest/download` asset so it always resolves to the
  newest release's appcast.

### Engine-update surfacing
- DTOs `UpdateCheck`, `UpdateApply` mirroring the engine. `SvodClient.updateCheck() ->
  UpdateCheck`, `updateApply() -> UpdateApply` (Live: GET/POST `/api/v1/update/*`, not
  vault-scoped; Mock: canned "up to date" / a fake newer version).
- `UpdatesSettingsView` (new Settings section "Updates"): two cards —
  **App** (current version, "Check for Updates…" → Sparkle, auto-check toggle) and
  **Engine** (current/latest, "Update engine" → `updateApply`, with a confirm; shows
  "up to date" / "needs a newer engine" on 501). Graceful 404/501.

### Release CI + appcast (`.github/workflows/release.yml`, UI)
- On tag `v*`: build Release `Svod.app`. If signing secrets present
  (`DEVELOPER_ID`, notarization creds, `SPARKLE_ED_PRIVATE_KEY`): codesign → notarize →
  staple → zip → `sign_update` (Sparkle) → generate/append `appcast.xml` → upload zip +
  appcast to the release. If absent: upload an **unsigned** zip + skip the appcast, and
  `echo` a clear "signing secrets missing — no auto-update artifact" (non-fatal).
- EdDSA keypair generated with Sparkle's `generate_keys`; **public** key → Info.plist
  (committed); **private** key → user stores in 1Password + GH Actions secret (NEVER
  committed). Documented in `docs/release-signing.md`.

## Security
- Engine: apply is compat-gated + sha256-verified; never auto-applies without the
  user's click; runs out-of-process.
- UI: Sparkle EdDSA private key never in the repo; updates only install if signed by
  the matching key + the app is notarized.
