# Svod UI — import landed in wrong vault (fix 2026-06-23)

## Bug
Import into a non-default vault (e.g. new "Lukanet") reported "N files imported" but the vault stayed EMPTY; files actually landed in the DEFAULT vault (`personal`).

## Root cause
Engine `POST /api/v1/import` (AppApiServer.kt ~L408) resolves the target via `vault()` = `call.request.queryParameters["vault"]` — the **`?vault=` query param**. It does NOT read the `vault` field from the JSON body (`ImportRequestDto.vault` is dead). The UI's `LiveSvodClient.importVault` was sending vault only in the **body** (`ImportRequest(...vault:...)`) and never on the URL, so the engine fell back to the default vault. (Memory note "/import NOT per-vault" was wrong/stale — import IS per-vault via `?vault=`.)

## Fix (svod-ui-macos, build green, NOT yet committed at time of writing)
`Svod/Networking/LiveSvodClient.importVault` now passes `query: vaulted(vault: vault)` so `?vault=` is sent. `vaulted(vault:)` appends `?vault=` for a non-nil id and omits it for the default (nil) — correct either way.

## Recovery pattern (when files import into the wrong vault)
1. Find the mis-import commit in the wrong vault: `git -C ~/Svod/<wrong> log --oneline` → e.g. `import: 101 files`.
2. Reconstruct the source: `git show --name-only --pretty=format: <sha>` → copy those exact paths from the working tree into a temp staging dir preserving structure.
3. Re-import into the right vault via engine API (engine on :7619): `POST /api/v1/import?vault=<right>` body `{source, into:"", vault, followSymlinks:false}`. Additive/idempotent.
4. Remove from the wrong vault: `rm` exactly those paths, `git add -A && git commit`, then `POST /api/v1/maintenance/reindex?vault=<wrong>` so the search index matches HEAD. Manual git commits in a vault are fine (git-as-substrate); reindex syncs the index.

## Env reminders
Engine runs from-source on :7619 (not launchd :7517). Probe HTTP via ctx_execute JS `fetch` (curl blocked by context-mode hook). App must be relaunched to pick up the rebuilt binary; switch vaults to force sidebar reload (reloadEpoch).
