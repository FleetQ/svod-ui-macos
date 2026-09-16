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
## HAZARD — installDist swaps the jar under the RUNNING JVM (hit 2026-08-17)

`build/install/svod-engine/lib/` IS the live engine's classpath. Running `installDist` while
:7619 is up replaces the jar the JVM is still lazily loading classes from. Routes already
exercised keep working, so **the damage is invisible until something hits a cold code path** —
here `/api/v1/graph` began returning `500 dev/svod/engine/api/GraphNodeDto`, a class that had
simply never been loaded before the swap.

- **Never run installDist from a feature branch while the daily driver is up.** Build in a
  separate `git worktree` (`git worktree add --detach /tmp/x <ref>`), then copy the jar over and
  `kickstart` — that way the live engine only ever changes at a restart boundary.
- Recovery from an already-swapped jar: build the intended ref in a worktree, copy its
  `svod-engine-<version>.jar` into the live lib dir, `launchctl kickstart -k gui/501/dev.svod.engine`.
- After any installDist, check the lib dir holds exactly ONE `svod-engine-*.jar` — the classpath
  is a `lib/*` glob, so a leftover old jar puts two versions on it.

- Restart timing: kickstart -k SIGKILLs the old proc; there's a ~2s port-bind overlap
  (a `BindException` shows in engine.err.log — HARMLESS, KeepAlive+ThrottleInterval retries)
  then the cold start below. Poll ~30s; a restart that has not answered in a minute is a real
  failure now, not a slow boot.

## Cold start — AUTHORITATIVE, since engine v1.18.1 (2026-08-18)

**~13 s on the 3,096-note `personal` vault. The old "25 s – 7.5 min, poll up to 8 min" advice is
DEAD** — it is still quoted in older memories as history; do not act on it.

Per-phase, from the `vault <id>: <phase> took <n> ms` lines v1.18.0 added to `VaultContext`:

| phase (`personal`) | before v1.18.1 | now |
|---|---|---|
| engine open | 15,340 ms | ~0.9–1.4 s |
| index start | 1 ms | 1–5 ms |
| file watcher start | 34,491 ms | ~1.7–2.8 s |
| graph start | 2,380 ms | ~2–3 s (now the largest) |
| **`/ready`** | **~52 s** | **12.6–14.0 s** |

Two causes, both measured, both fixed in v1.18.1:

1. **The watcher hashed file CONTENT under the vault root** — 97 MB `.git` + 839 MB `.svod`
   (Lucene), which the listener then discards by path. `DirectoryWatcher.build()` is only 141 ms;
   **`watchAsync()`** is what blocked. Now `FileHasher.LAST_MODIFIED_TIME`. Chosen over the two
   *faster* options on purpose: `fileHashing(false)` drops the de-duplication that suppresses an
   event for a touched-but-unchanged file, and watching hand-picked children instead of the root
   silently stops watching new top-level entries.
   *The tell that cracked it: `work`, a **two-note** vault, paid 4,717 ms — so the cost was never
   about notes.*
2. **`recover()` ran `commitAll` on every boot** — jgit `add`/`status` stat every tracked file, a
   cost this codebase had already documented and routed around for the write path (`commitPaths`)
   but never for boot. Native `git status --porcelain` answers the same question in **20 ms vs
   15.3 s** and now gates it. Recovery is NOT narrowed: an offline edit is an uncommitted change,
   `status` sees it, the commit still happens; any failure to answer falls through to the full walk.

Guarded by `ColdStartTest` + the pre-existing `CrashRecoveryTest` (both fail if the skip is made
unconditional) and by a same-length-rewrite watcher test (the risk of mtime+size vs content).

**If a boot is slow again, read the phase lines first** — they are already in the log, and they are
what turned "cold start is 25 s – 7.5 min" from folklore into two fixable numbers.

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
  ~55s live — the old 24s estimate is a lower bound). Both figures are pre-v1.18.1 history.
- Diagnosis tell-tale seen that day: agent at `runs = 81` (crash loop on
  `BindException: Address already in use` while something else held :7619), then booted
  out entirely. Check BOTH: `launchctl print gui/501/dev.svod.engine` AND
  `lsof -nP -iTCP:7619 -iTCP:7620 -sTCP:LISTEN` before restarting.

## App reconnect dead-state (FIXED 2026-07-03, uncommitted → check git log for EngineModel)
- Symptom: engine restart via UI "did nothing", app sat with ZERO tcp sockets while the
  engine was long ready. Root cause: `EngineModel.connect()` had NO retry-on-failure —
  the 1.6–8s backoff only ran via `handleDisconnect()` (i.e., after a previously
  SUCCESSFUL connection dropped), and even that chain died after one failed attempt.
  App launched during an engine cold start (25s–7.5min as it was THEN; ~13 s since v1.18.1) → one failed /ready →
  parked in `.disconnected` forever until app relaunch.
- Fix: `scheduleRetry()` (retryTask + backoff) called from every connect() failure path,
  start()-timeout, and handleDisconnect; cancelled on explicit disconnect()/stop() and
  on successful connect; skips a tick while `.starting` (start()'s poll owns the flow).
- Verified live: debug build + argument-domain override (`Svod -svod.settings.endpointPort 7998`,
  not persisted) against a dead port, fake /ready node server brought up 15s later →
  app connected on its own within 3s.

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

## v1.19.0 cut (2026-08-20) — and two release-process defects it exposed

Cut correctly: both version places bumped in one `chore(release)` commit, tag on the bump commit,
live `update/check` shows current == latest == 1.19.0 with no phantom update, enclosure URL
returns 206 on a range request. **All 6 assets uploaded** (v1.18.0 managed only 4).

Two defects found by verifying by hand rather than trusting the workflow's green tick:

1. **`generate_release_notes: true` on all three matrix jobs** → each regenerates and appends the
   body, so every release from at least v1.17.0 to v1.19.0 shipped its changelog printed THREE
   times. Fixed: only the linux job generates it. Nobody had looked at a release body closely.
2. **`fail_on_unmatched_files: false`** means a missing artifact never fails a job — which is
   exactly how v1.18.0 shipped 4/6 assets across three "successful" jobs. **Always enumerate
   `gh release view <tag> --json assets` after a cut; the job conclusion cannot tell you.**

**This release forces a one-time re-embed** for Ollama/bge-m3 vaults (the e5-prefix fix changed
what the vectors contain). ~2 h on a 3,096-note vault; keyword search stays up throughout. e5
vaults are untouched. See the retrieval-quality memory for the measurements.

## v1.19.1 cut (2026-08-27) — contract 0.29.0

Fixes a vault created at runtime being only half-wired until the next restart (backup binding, MCP
tool set, source watching were all startup-built maps). Detail in `svod-backup-sync`. Cut via PR #17
→ squash-merge → tag on main. Local update was the plain `installDist` + `kickstart` path (safe: on
`main`, not a feature branch), lib dir verified to hold exactly one jar. **Cold start measured 29.5 s
this time**, not the usual ~13 s — the release workflow was compiling on the same machine; do not
read a single loaded-machine boot as a regression.

**CI vs local on `OnnxRerankerTest`**: the reranker latency test (`50 realistic pairs … ceiling is
4000ms`) fails locally at ~4.5 s under load but is **skipped on CI** — it `assumeTrue`s the model is
cached and the runner has no cache. So a green CI says nothing about it either way; check it locally
against the *unchanged* tree before blaming a diff (it failed at 4469 ms with everything stashed).

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

## v1.20.0 / v1.21.0 cut (2026-09-05) — people as principals, then the security hardening
- Both deployed to :7619 from `main` via installDist + kickstart; both tagged and released by CI (6 assets each). Cold start measured 48 s under xcodebuild load, 16 s idle. `mem:svod-shared-vault-sprint-1`, `mem:svod-shared-vault-sprint-2a`.
- **The live config stays single-user** (no `users[]`, `localAdmin` default true): `/me` = `svod-ui` admin, every vault `role: admin`. What DID change on this Mac: a keyless loopback request is the local UI only with a loopback `Host` and no foreign `Origin` — a browser page (DNS-rebound, or a cross-origin WebSocket) gets 401. The app and the MCP bridges send `Host: 127.0.0.1:7619` and no `Origin`, so nothing broke; verified live after the restart.
- **Files the engine now writes next to the config** (`dist/`, because the live config is `dist/config.local.multivault.json`): `dist/secrets/` (keys, `POST /secrets`), `dist/audit-api.log` (people audit; on this Mac only refused requests land there, e.g. my browser-threat probes as `anonymous` 401), `dist/user-activity.json`. All three are git-ignored; `git add -A` in the repo root is safe again. `/metrics` stays open here (localAdmin=true).
- `.svod/audit/audit.log` (MCP agents) is created 0600 since 1.21.0; the four real vaults' files were 0644 and get restricted on the first agent write after the restart — check `ls -l ~/svod/*/.svod/audit/audit.log`.
- Never `installDist` from a feature branch while :7619 is live still holds — this sprint built in `git worktree`s (`svod-wt-shared`, `svod-wt-shared2`) and deployed only after the squash-merge landed on `main`. A checkout that shares the branch with a worktree (it happened once) shows the branch's later commits as a staged REVERSAL in the other checkout — nothing is lost, `git reset --hard && git checkout main` after the merge.
