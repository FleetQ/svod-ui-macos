# Svod — shared (company) vault: requirements brainstorm, 2026-09-05

Full doc: `~/htdocs/svod/docs/requirements-shared-vault.md` (status: ready for `/sc:design`). This memory holds only the decisions and the non-obvious findings.

## What the code check found (observed 2026-09-05)
- Multi-machine sync works (git bus on `refs/svod/sync/<vault>`), but the implementation is **symmetric** — every machine merges itself (`SyncEngine.kt:18` "no authority/replica"), NOT the authority model ADR-0009 describes.
- **Humans have no identity.** Every App API edit is authored `svod-ui <ui@svod.local>` (`AppApiServer.Config.uiAuthor`); only MCP agents carry their own author. Committer = hostId (`VaultContext.kt:81`).
- Roles exist only for MCP agents (READ_ONLY/WRITE + vault grants). App API = loopback-only, no auth (invariant 7).
- New machine joins only via CLI `svod-engine clone` with the engine stopped.
- GitHub Connect (`GitHubBackup.swift`) creates the repo via `POST /user/repos` → under whichever account the browser is logged into; **no org/owner choice**. Token lives per vault in `~/Library/Application Support/Svod/backup-<vault>.remote`.
- Moving a vault between GitHub accounts needs no repo transfer: reconnect to the new account + backup now pushes the full history from the local clone. Only other syncing machines must be repointed (their `.remote` is per machine).

## Owner decisions (two rounds of questions)
- 10–15 people → shared token unacceptable; **per-person credentials + roles reader/editor per vault**.
- **Central engine on a server; macOS app stays local** and points to the central engine *per vault* (personal vaults stay on the local engine). Host/admin undecided; must be configurable in vault settings, not a design input.
- **Offline must be possible** → hybrid: online mode (talk to central engine directly, default) + optional **replica** mode (local clone syncing against the central engine, using the person's credential — people never get the GitHub token).
- Credentials: **admin-issued API keys first, SSO foreseen** as an extension, same role/vault model.
- SocialScore goes to a **different org repo** (move or new + push history); the GitHub remote must be settable from the app's vault settings even for a remote engine; token stays on the server as a Secrets ref.
- Central engine may hold more than one company vault (multi-vault already).
- Presence ("X is editing now") = nice-to-have; 409 + 3-way merge on concurrent save (already works) is the accepted baseline.

## Design-level consequences (for the ADR)
- App API must gain network bind + TLS + per-user auth + author = the human. Obvious candidate: extend the existing agent model (token → identity → role → vaults, hot-reload, audit log) to humans.
- App needs per-vault engine endpoints (today one global host/port).
- Interim for SocialScore today (no code): org account creates repo + fine-grained PAT, overwrite `backup-socialscore.remote`, `PUT /settings/backup?vault=socialscore`, `POST /backup/now`, verify with `git ls-remote`.

Related: `mem:svod-backup-sync`, `mem:svod-ui-multivault`, `mem:svod-ui-llm-access`.
