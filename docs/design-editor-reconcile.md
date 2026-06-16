# Editor reconcile on external change — design + plan

> Sprint artifact (think + plan, condensed — the requirements were settled in
> `docs/design-multimachine-sync.md`). The last slice of multi-machine sync.

## Problem (think)

- **Who / today:** A user editing a note while a sync pull (or an agent, or the
  file watcher) rewrites that same file underneath. Today the editor holds a stale
  `file.revision`; the incoming change is invisible until reload, and a later save
  can 409 or silently fight the sync.
- **Narrowest MVP:** When the *open* note changes on disk, don't lose the user's
  unsaved buffer and don't show stale content.
- **"Whoa":** It just stays correct — clean buffers adopt the new content silently;
  unsaved edits open the existing 3-way merge instead of being clobbered.
- **Compounds:** Same mechanism covers sync pulls, agent writes, and the watcher —
  any external writer. No per-source code.

## Decisions

1. Trigger on the existing `file.changed` WS event (no new contract surface).
2. Act only when the event targets the **open** note in the **active vault**.
3. Reconcile policy:
   - **Buffer clean** (`!dirty`) → adopt incoming content silently (update `file` +
     `draft`, keep `dirty == false`).
   - **Buffer dirty, incoming == buffer** → no conflict; just adopt the fresh
     revision so the next save won't 409.
   - **Buffer dirty, incoming differs** → surface the existing conflict flow
     (`presentConflict(ConflictBody)`, base/ours/theirs) — never clobber.
4. Skip while a local save is in flight (`isSaving`) — our own write updates state.
5. Skip if the fetched revision equals the current one (our own echo / no-op).

## Architecture (plan)

- `EditorModel.reconcileExternalChange(path:)` — new method holding policy above.
  Reuses `client.readFile`, `suppressAutosave`, and `app.presentConflict`.
- `EngineModel` event loop — on `.fileChanged`, call it with `event.data.path`,
  gated on the event's vault matching the active vault (best-effort; nil ⇒ allow).
- No DTO/contract changes. No new UI — the conflict path already exists.

## Test plan / acceptance

| Case | Expected |
|---|---|
| Open note clean, external change | Editor adopts new content; not dirty |
| Open note dirty, external change differs | 3-way merge sheet opens; buffer intact |
| Open note dirty, external change == buffer | No conflict; revision adopted (no later 409) |
| External change to a *different* note | Open note untouched |
| External change in a *different* vault | Open note untouched |
| Our own save echoes back | No reload, no conflict |
| `file.changed` while saving | Ignored (save owns the state) |

Verification: build (no test target wired in this repo — manual + preview). Trace
the event path against the live engine where practical.
