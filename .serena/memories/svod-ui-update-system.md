# Svod — update system (engine self-update + app Sparkle) — session 2026-06-29

Adds an update path to both halves. Engine: notify + one-button apply. App: Sparkle
auto-update. Builds on the LLM-access work (`mem:svod-ui-llm-access`); same delegation
+ recovery pattern. UI `9d97f18` on main + pushed; engine `9857099` on main + pushed +
DEPLOYED live to :7619 (apiVersion **0.18.0**).

## Engine (FleetQ/svod-engine, `9857099`, contract 0.17.0 → **0.18.0**)
- `GET /api/v1/update/check` → `UpdateCheckDto { currentVersion, currentContract,
  latestVersion?, updateAvailable, compatible, assetName?, assetUrl?, sha256?, notes?,
  publishedAt? }`. `UpdateService` queries GitHub `releases/latest` (java.net.http,
  10s, UA header), compares app-version semver via `ApiCompatibility.SemVer`:
  updateAvailable = latest>current, compatible = same MAJOR. A failed fetch → 200
  updateAvailable=false (NEVER 500). Injectable `releaseFetcher` → offline unit tests.
- `POST /api/v1/update/apply` → 202 `{started,candidateVersion}`; **409** NotApplicable
  when no/incompatible update; **501** NotSupported when `SVOD_SELF_UPDATE_SCRIPT`
  unset. Spawns the DETACHED `dist/self-update.sh` (download→sha256→atomic swap→
  `launchctl kickstart`); engine never swaps itself in-process.
- `dist/self-update.sh` finished (port 7619 not the stale 7517; args
  `<version> <asset-url> [sha256]`; temp-dir trap; fail-closed sha256).
- Files: `api/UpdateRouting.kt` (UpdateAdmin + NotSupported/NotApplicable),
  `lifecycle/UpdateService.kt`, AppDtos, AppApiServer (2 routes, `updateAdmin`), SvodNode.
  Tests `UpdateServiceTest` (6) + AppApiContractTest. Full suite green.
- LIVE VERIFIED on :7619: apiVersion 0.18.0; check → updateAvailable=false /
  compatible=true vs the real v1.7.0 release (asset+sha256+notes populated); apply →
  409 (nothing to apply). apply NOT live-triggered (disruptive).

### Engine KNOWN FOLLOW-UPS (apply path, not yet functional end-to-end)
1. **Asset selection bug**: `parseRelease` picks the FIRST asset whose name contains
   the host label → on macOS it grabs `svod-engine-macos-arm64` (native binary) instead
   of `SvodEngine-macos-arm64.tar.gz` (the app-image the script expects). Prefer the
   `SvodEngine-*.tar.gz`/`.zip` app-image asset before enabling apply.
2. apply only works on a **launchd-managed app-image** deployment with
   `SVOD_SELF_UPDATE_SCRIPT` set + `SVOD_INSTALL_DIR`/`SVOD_LAUNCHD_LABEL` matching. The
   dev :7619 engine runs via `nohup java … MainKt` (installDist), NOT launchd → apply
   stays 501/inert there by design.

## App (FleetQ/svod-ui-macos, `9d97f18`)
- **Sparkle 2.9.3 via SPM** — the project's FIRST package dep, added by hand-editing
  `Svod.xcodeproj/project.pbxproj`: PBXBuildFile (Sparkle in Frameworks),
  packageReferences (XCRemoteSwiftPackageReference), target packageProductDependencies
  (XCSwiftPackageProductDependency), Frameworks phase. Validated via
  `xcodebuild -resolvePackageDependencies` + a full build.
- `App/Updater.swift` wraps `SPUStandardUpdaterController`; "Check for Updates…" in the
  app menu (`CommandGroup(after:.appInfo)`); injected into Settings via env object.
- **Info.plist GOTCHA**: `INFOPLIST_KEY_<custom>` does NOT inject arbitrary keys (only a
  known allow-list) → SUFeedURL/SUPublicEDKey were missing from the built app. Fix:
  explicit `Config/Info.plist` (`GENERATE_INFOPLIST_FILE=NO`, `INFOPLIST_FILE`). It must
  live OUTSIDE the `Svod/` `PBXFileSystemSynchronizedRootGroup` — inside it, the synced
  group also copies it into Resources (warning + dup). Hence `Config/Info.plist`.
  Keys: SUFeedURL=`…/releases/latest/download/appcast.xml`, SUPublicEDKey, SUEnableAutomaticChecks.
- Settings → **Updates** panel: App card (Sparkle: version, Check for Updates, auto-check
  toggle) + Engine card (`updateCheck`/`updateApply`, graceful 501 → "needs newer engine").
  DTOs `UpdateCheck`/`UpdateApply` + `SvodClient.updateCheck()/updateApply()` (Live+Mock).
- **Sparkle EdDSA key**: reused the pre-existing login-Keychain key; public
  `tjHC4d/AW4IC/MJKOvftiezy501Fe+rq/rAGg2r4EhQ=` committed in Info.plist. Private stays in
  Keychain (export for CI: `generate_keys -x`).
- `.github/workflows/release.yml` (UI): on tag `v*`, build Release; if signing secrets
  present → codesign(Developer ID)→notarize→staple→zip→Sparkle `generate_appcast`→upload
  zip+appcast; else unsigned zip + a `::warning::` (non-fatal). `docs/release-signing.md`
  lists the 7 secrets. This CI is UNVALIDATED (no secrets, not triggered).

### App VALIDATION BOUNDARY (hard, cannot cross here)
No `DEVELOPMENT_TEAM`/Developer ID configured → Sparkle's actual **download/install is
NOT validatable**. Delivered + validated up to: SPM resolves, app builds+links+embeds
Sparkle.framework, Info.plist carries the SU keys, "Check for Updates" wired. Installing
needs the user to add Developer ID + notarization creds + the Sparkle private key as GH
secrets and cut a signed release. The engine `/update/check` path IS fully validated live.

## Process — harbormaster ~600s wall (4th & 5th occurrences; now a firm rule)
The engine delegation hit the 600s `claude -p` wall BOTH times this sprint. First update
attempt: produced NOTHING (burned budget on reading). Re-delegated with a tighter,
"commit after EACH file" brief + `auto_commit:false` → STILL timed out, ignored the
commit-early instruction, but THIS time left all files written-but-uncommitted. RULE:
treat a `status:failed` engine delegation as "work probably present, uncommitted" — ALWAYS
`git status` the svod tree first; review the files; `./gradlew test --rerun-tasks` via
`ctx_execute`; commit the real files (exclude the agent's `claudedocs/`+`retro/` scratch);
then installDist + restart :7619 + live-verify. Two-attempt delegation then self-finish is
the reliable shape; don't loop delegations. Deploy recipe unchanged (see
`mem:svod-ui-llm-access`): installDist → SIGTERM `pgrep -f dev.svod.engine.MainKt` →
rm `~/Svod/*/.svod/lock` → `nohup java -cp 'build/install/svod-engine/lib/*' MainKt <config> &`
→ poll /ready. Releases NOT cut this sprint (user said "don't assume"); offered instead.
