# Multi-machine sync — design direction

> Status: requirements/design spec (no implementation yet). Produced from a
> `/sc:brainstorm` session, 2026-06-16. Bulk of the work is **engine-side**;
> this repo (the macOS UI) hosts the design record and the UI slice.

## Goal

Edit the same vault on 2–3 of my own Macs and have them converge without data
loss and without ever touching git by hand.

## Locked decisions

| Axis | Decision | Why |
|---|---|---|
| Topology | **Shared git repo as the sync bus** | Vaults are already git repos; engine already speaks git; GitHub backup repo already wired; 3-way conflict UI already exists. No always-on server. |
| Freshness | **Periodic poll (minutes)** + on launch/focus + after edits settle + manual | No server needed. Mirrors the existing 15-min backup cadence. |
| Conflicts | **Auto-merge; surface only real line-overlap** | Calm UX, never lose data. Non-overlapping edits merge silently (git 3-way). |
| Scope | **My machines only, single user** | No per-user auth/permissions. The shared repo token is the trust boundary (already true for backup). |

## Mental model

Sync = *distributed git with automatic, headless reconciliation*. One canonical
ref on the shared remote is the rendezvous point. Each machine fetches, merges,
commits, and pushes on a schedule. **Sync subsumes backup** — once a vault is
synced, the remote always holds full history, so the one-way backup ref becomes
redundant for that vault.

### Canonical ref

- Sync uses a dedicated canonical ref, e.g. `refs/svod/sync/<vaultId>` (or
  `refs/heads/main` of a per-vault repo). Distinct from the legacy one-way
  `refs/svod/backup/<vaultId>`.
- **Open question:** reuse the existing backup repo (different ref) or a separate
  repo? Recommendation: same repo, sync ref is canonical, retire the backup ref
  for synced vaults.

## The sync cycle (engine, per vault, single-flight)

Runs under a **per-vault git lock** — all local writes (editor saves, agent
writes, imports) queue behind it. This also removes the `rm -f index.lock`
startup hack, which is a symptom of today's lock contention.

1. Acquire the per-vault lock.
2. Commit pending local changes (engine already auto-commits) → clean tree.
3. `git fetch <remote> <syncRef>`.
4. **Up to date** (remote == local) → status `inSync`, done. *(This is also the
   correct answer to the current "Backup failed" no-op confusion.)*
5. **Fast-forward** (local is ancestor of remote) → `merge --ff-only` →
   reindex changed paths → push (no-op) → done.
6. **Diverged** → `git merge <remote>/<syncRef>` (recursive 3-way):
   - Clean auto-merge → commit the merge → continue.
   - Real conflict (overlapping hunks, or modify/delete) → abort the merge,
     record each conflict (base/ours/theirs — already in the contract) into the
     conflict queue, leave the local working state intact. User resolves via
     `POST /conflicts/resolve`, which commits the merge. Then continue.
7. **Push** `HEAD:<syncRef>`:
   - Rejected (non-fast-forward — another machine pushed meanwhile) → re-fetch,
     re-merge (back to step 3), retry. Bounded retries with backoff (~5).
8. **Secret scan** incoming files (defense-in-depth) → quarantine + flag any that
   fail; never write a leaked secret into the vault.
9. **Incremental reindex + re-embed** of changed paths only; emit `index.updated`.
10. Update `lastSyncedAt` / `head`; emit sync-status event.
11. Release the lock.

## Triggers

- Interval timer (configurable; default ~3 min).
- App launch / window focus → UI calls `syncNow`.
- After local edits settle (debounced; reuse the `backupOnChange` precedent).
- Manual **Sync now**.

## Identity & attribution

- Stable per-machine `hostId` (already in the contract).
- Commits carry the machine (committer = `<hostId>`) and preserve agent
  attribution, so history/blame and the conflict UI can show
  "edited on MacBook 14:03 vs iMac 14:05".

## Edge cases (the "without problems" list)

- **Offline for a week** → divergence on reconnect → handled by step 6.
- **Push race between machines** → non-ff rejection → re-merge + retry (step 7).
- **Modify/delete & rename/edit** → real conflict, surfaced (reuse the
  external-source orphan/soft-delete semantics already in the engine).
- **index.lock contention** (already observed) → fixed by the per-vault serial
  git queue; retire the startup `rm -f index.lock`.
- **Open editor buffer vs incoming change** *(UI-side, important)* → when sync
  rewrites a file that's open with unsaved edits, the editor must reconcile:
  reload on `file.changed` when the buffer is clean; if dirty, raise a small
  in-editor conflict instead of silently clobbering or losing the buffer.
- **New machine bootstrap** → "Add this Mac to a synced vault": clone
  `<remote> <syncRef>` into `~/Svod/<vault>`, assign a fresh `hostId`, register.
  New UI flow + engine endpoint.
- **Large/binary attachments** → git LFS is **out of scope**; flag as a known
  limitation.

## Work breakdown

**Engine (most of it):**
- The sync cycle above; `role: synced` (today only `solo`/peer scaffolding).
- `syncNow` actually does the cycle for synced vaults (today no-ops for solo).
- Canonical sync ref + stable `hostId` + per-vault git lock/queue.
- Bootstrap/clone endpoint for adding a machine.
- Sync-status field set: `inSync | syncing | conflicts(n) | offline | error`.

**Contract:**
- Sync-status fields + `lastSyncedAt` (have `lastBackupAt`).
- Distinguish "sync remote" config from "backup remote" (or unify).
- Bootstrap/clone endpoint shape.
- (Bonus, unrelated but adjacent) backup no-op should return `ok:true` /
  `noChange:true` — already filed separately.

**UI (this repo):**
- Per-vault sync-status pill (in sync / syncing / N conflicts / offline).
- Wire **Sync now** for synced vaults; enable-sync toggle + interval in Settings.
- "Add this machine to a synced vault" flow (clone).
- Surface the conflict queue (3-way merge UI mostly exists).
- Editor reconcile-on-external-change (buffer vs incoming sync write).

## Non-goals

Real-time collaborative editing (live cursors), multi-user permissions, a central
server, P2P/LAN transport, CRDTs. This is periodic git sync for one user's own
machines.

## Open questions to resolve before build

1. Reuse backup repo with a sync ref, or a separate repo? (Recommend: reuse.)
2. **Merge vs rebase** on divergence? (Recommend: merge — preserves both
   histories, simpler conflict story.)
3. Retire the one-way backup ref for synced vaults, or keep both? (Recommend:
   retire — sync is a strictly better backup.)
4. Default poll interval and edit-settle debounce values.
