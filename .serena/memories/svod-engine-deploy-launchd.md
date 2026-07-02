# Svod engine — :7619 deploy mechanism + version-report bug (2026-07-01)

Corrects `mem:svod-ui-update-system` / auto-memory which said the :7619 engine runs
"from-source, NOT launchd" and is "v1.8.0". Both were wrong.

## The :7619 engine IS launchd-managed
- Plist: `~/Library/LaunchAgents/dev.svod.engine.plist` (Label `dev.svod.engine`,
  RunAtLoad, KeepAlive on non-successful exit, ProcessType Background, logs at
  `~/Library/Logs/svod/engine.{out,err}.log`).
- It execs `~/Library/Application Support/Svod/run-engine.sh`, which runs:
  `java -cp "~/htdocs/svod/engine/build/install/svod-engine/lib/*" dev.svod.engine.MainKt ~/htdocs/svod/dist/config.local.multivault.json`
  (JAVA_HOME jdk-20). Classpath is a `lib/*` GLOB → a rebuilt jar is picked up on restart
  without editing anything. run-engine.sh also rm's `~/Svod/*/.git/index.lock` first.

## Deploy recipe (source → live)
1. `cd ~/htdocs/svod/engine && JAVA_HOME=$(/usr/libexec/java_home -v 20) ./gradlew installDist`
   → regenerates `build/install/svod-engine/lib/svod-engine-<version>.jar` (removes old jar).
2. `rm -f ~/Svod/*/.svod/lock` (stale lock guard)
3. `launchctl kickstart -k gui/501/dev.svod.engine` (uid 501)
4. Poll readiness with a **JS fetch** to `http://127.0.0.1:7619/ready` — NOT curl
   (context-mode hook silently blocks curl/wget → empty output looks like "refused").
- Restart timing: kickstart -k SIGKILLs the old proc; there's a ~2s port-bind overlap
  (a `BindException` shows in engine.err.log — HARMLESS, KeepAlive+ThrottleInterval retries)
  then a ~24s cold start (Lucene mmap). Poll for ~40-60s; don't conclude failure early.

## Stop→Start dead-end (UI, FIXED in app v0.2.2 — 2026-07-02)
- App's Settings→Engine **Stop = `launchctl bootout`** → the agent is fully UNLOADED from
  gui/501 (`launchctl print` → "Could not find service"). Pre-0.2.2 `EngineModel.start()`
  only ran `kickstart` (fire-and-forget Process, exit code ignored) → kickstart on an
  unloaded agent fails silently → Start after Stop ALWAYS timed out ("Timed out waiting
  for the engine. Check the launchd agent.").
- Manual recovery: `launchctl bootstrap gui/501 ~/Library/LaunchAgents/dev.svod.engine.plist`
  then `kickstart gui/501/dev.svod.engine`.
- Fix (commit `d1fe6d3`, shipped app v0.2.2): start() runs launchctl via a nonisolated
  async helper with exit-status check; on kickstart failure it bootstraps the plist and
  retries; /ready poll window 20s→90s (real cold start incl. semantic-index check took
  ~55s live — the old 24s estimate is a lower bound).
- Diagnosis tell-tale seen that day: agent at `runs = 81` (crash loop on
  `BindException: Address already in use` while something else held :7619), then booted
  out entirely. Check BOTH: `launchctl print gui/501/dev.svod.engine` AND
  `lsof -nP -iTCP:7619 -iTCP:7620 -sTCP:LISTEN` before restarting.

## The version-report bug (FIXED → v1.8.1, commit 379d354)
- `GET /api/v1/update/check`'s `currentVersion` comes from `UpdateService(currentAppVersion=…)`
  constructed in `engine/.../lifecycle/SvodNode.kt` with a **HARDCODED string**. It was left
  at `"1.7.0"` when v1.8.0 was cut → the engine perpetually reported itself as 1.7.0 and
  advertised a phantom "1.8.0 available" self-update that never cleared. (Tell-tale: the
  rebuilt jar was byte-identical in size — only the constant differs between versions.)
- FIX: bumped `SvodNode.currentAppVersion` AND gradle `version` (build.gradle.kts:15) to
  "1.8.1", cut a clean patch release (re-tagging published v1.8.0 would be destructive; the
  released v1.8.0 artifact carried the same bug).
- DRIFT RISK REMAINS: version lives in TWO places (the constant + gradle `version`) with NO
  consistency test — `UpdateServiceTest` injects its own version so it can't catch this.
  Durable fix (offered, not done): read Implementation-Version from the jar manifest.

## v1.9.0 cut correctly (2026-07-02)
Bumped BOTH version places in one commit (`7c79a92`: gradle `version` + `SvodNode.currentAppVersion`) → live `update/check` shows current==latest==1.9.0, no phantom. CI note: the windows job logs a NON-FATAL "Could not setup Developer Command Prompt / input line too long" (MSVC vcvarsall) warning — all 6 assets still published; first place to look if the windows binary ever misbehaves.

## Release process (svod-engine, FleetQ/svod-engine, SSH remote)
- Tag-triggered: `git tag vX.Y.Z && git push origin vX.Y.Z` → `.github/workflows/release.yml`
  builds a 3-OS matrix (macos-arm64/linux-x64/windows-x64), ~9 min. Assets per release:
  native binaries `svod-engine-<os>` + app-images `SvodEngine-<os>.tar.gz/.zip`.
- `ci.yml` runs engine tests on push/PR to main.
- Asset-selection note (still open from `mem:svod-ui-update-system`): update/check's
  `parseRelease` picks `svod-engine-macos-arm64` (native binary), NOT the `SvodEngine-*.tar.gz`
  app-image the self-update script expects — apply path still not wired for this installDist
  deploy anyway (needs launchd app-image + `SVOD_SELF_UPDATE_SCRIPT`).

## App connection (verified)
`/Applications/Svod.app` (bundle `dev.svod.Svod`, v0.2.0) reads endpoint from UserDefaults
domain `dev.svod.Svod` keys `svod.settings.endpointHost/Port` = 127.0.0.1:7619. So the app
correctly targets the launchd engine. The screenshot "This engine doesn't support self-update"
(needs a 404/501 from update/check) was from an EARLIER moment when :7619 ran a pre-0.18.0
engine — current engine returns 200 and supports it.
