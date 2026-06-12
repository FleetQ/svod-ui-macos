# Svod UI — Settings: Requirements Specification

Status: requirements discovery (output of `/sc:brainstorm`). No architecture/code here.
Next: `/sc:design` (architecture) or `/sc:workflow` (implementation plan).

## 1. Goal

Give the personal Svod macOS client a **Settings surface** that lets the user (a)
point the UI at the right local engine, (b) control the engine's lifecycle, (c)
**see** multi-host sync / replication health, (d) eventually **configure** git
sync + backup remotes, and (e) tune appearance, editor, search, graph and activity
behavior — all consistent with the calm, dark-first, content-first design.

## 2. Hard constraints (the contract is authoritative)

These shape what is even possible and MUST be respected:

- **App API is loopback-only** (`127.0.0.1`, enforced at engine startup). The UI
  cannot talk to a remote engine over this API. "Remote" only ever means: a
  different **local** endpoint/port, or a remote reached via an **SSH tunnel** that
  makes it appear on loopback.
- **`/api/v1/settings` is read-only** — no write endpoint exists. The UI cannot
  change vault path, ports, embedder, or git remotes through today's contract.
- **Multi-host is engine-level** (Step 7: replicated engines + git sync + a merge
  authority). The UI can **observe** it (`metrics.sync`, `/api/v1/conflicts`) but
  does not orchestrate it.
- Remote/backup auth secrets are resolved engine-side via `Secrets`
  (`env:` / `file:` / `keychain:`). The UI must never store raw secrets.

## 3. Feasibility legend

- ✅ **UI-side** — pure client preference, no engine change.
- 🔌 **Process** — uses `launchctl`/`Process` (already done for "Start Svod"), no contract change.
- 👁 **Read-only** — engine already exposes the data; UI only displays it.
- 🚧 **Needs new engine endpoint** — out of the UI's reach until the engine adds it.

## 4. Functional requirements by category

### A. Connection & endpoint  (user goal: "сменяем endpoint")
- A1 ✅ Editable engine endpoint `host:port` (default `127.0.0.1:7517`), persisted across launches (mirrors the reference web-viewer's stored endpoint).
- A2 ✅ Validate the endpoint (well-formed, loopback or tunnel) and show live reachability (reuses `ConnectionState`).
- A3 ✅ "Test connection" action → `GET /health` + `/ready`, report result.
- A4 ✅ (nice-to-have) Named **connection profiles** (a small list of endpoints) with a quick switcher; switching re-points the client and reconnects. Lays groundwork for multiple local vaults later without committing to it now.
- A5 ✅ Reconnect behavior: toggle auto-reconnect, surface current backoff state.

### B. Engine lifecycle  🔌
- B1 🔌 Start / Restart / Stop the local engine: `launchctl kickstart -k …` (start/restart) and `launchctl bootout …` (stop), keyed to label `dev.svod.engine`.
- B2 ✅/🔌 "Start engine automatically when the app launches" toggle (currently always attempts on launch).
- B3 👁 Show launchd agent state (loaded / running / crashed) where derivable.
- B4 🚧 (optional) "Reindex" / "Repack/gc" actions — no such endpoint exists today; capture as future engine ask.

### C. Sync & backup remotes  (user goal: "Sync + backup remotes")
- C1 👁 **Display** current sync role + status: `metrics.sync` (role, lastHead, conflicts) and the surfaced conflicts list (`/api/v1/conflicts`). Available now.
- C2 👁 Display configured remotes (backup target, sync peers) **if** the engine adds them to the read-only settings view (today `/settings` does NOT include remotes).
- C3 🚧 **Configure** backup remote (e.g. Hetzner push target) and multi-host **sync peers** + designate merge authority. Requires the engine to expose a **settings-write capability** (read+write sync/backup config) with startup-style validation and `Secrets`-referenced auth (SSH key / token). **Blocked on engine work.**
- C4 🚧 Trigger a manual "Sync now" / "Backup now". No endpoint today.
- C5 ✅ Clear in-UI messaging when C2–C4 are unavailable (so the panel reads as "view-only until engine support lands"), never a dead control.

### D. Appearance  ✅
- D1 Theme: Dark (default) / Light / Follow System. (App currently forces dark; tokens already support light.)
- D2 Accent: keep the single calm accent, optionally a small curated set.
- D3 Reading measure width (the ~70ch cap) and base text size; respects Dynamic Type.
- D4 Editor font (SF Mono default) + size + line-height.
- D5 Density: comfortable / compact row heights.

### E. Editor  ✅
- E1 Autosave on/off + debounce interval (vs explicit ⌘S).
- E2 Default focus/typewriter mode on open.
- E3 Default frontmatter template for new notes.
- E4 Wikilink behavior: autocomplete on/off, create-on-follow for unresolved links.
- E5 Spellcheck / smart quotes toggles.

### F. Search  ✅
- F1 Default mode: hybrid / keyword / semantic.
- F2 Default result limit.
- F3 Semantic on/off hint (note: semantic depends on engine embedder; UI only sets the default `mode`).
- F4 Remember last query / filters, or always reset.

### G. Activity feed  ✅
- G1 Which event types to show (agent.activity / commit.created / file.changed / conflict).
- G2 Max items retained; per-agent mute; per-agent color override.
- G3 Reduce-motion-aware entrance (already honored); toggle feed animation.

### H. Graph  ✅
- H1 Default scope (global / local).
- H2 Physics intensity / label density / freeze-when-settled threshold.
- H3 Respect Reduce Motion (already does); manual "static layout" toggle.

### I. Engine info (read-only)  👁
- I1 Display: vault path, API version, host, embedder provider/model/dim, index docCount + indexed head, write metrics (avg/max/last ms, queue depth). All already in `/settings`, `/index/status`, `/metrics`.

### J. Keyboard shortcuts  ✅
- J1 Display the shortcut map (⌘K, ⌘S, ⌘1/2/3, ⌥⌘I, sidebar toggle).
- J2 (nice-to-have) Customization/rebinding.

### K. Privacy & data  ✅/👁
- K1 Endpoint/profile data stored in `UserDefaults`; no secrets in UI (K-anchored to Keychain only if ever needed).
- K2 Clear local UI state (recent notes, window state, cached endpoint).

### L. General / startup  ✅
- L1 Reopen last note / restore window layout on launch.
- L2 Default pane visibility (sidebar/inspector) and default center mode.
- L3 Check-for-updates preference (the engine has an API-compat self-update path; UI update is separate/out-of-scope for now).

## 5. Non-functional requirements
- NFR1 Settings changes apply **live** without restarting the app wherever possible (theme, editor, search defaults, endpoint reconnect).
- NFR2 Persistence via `@AppStorage`/`UserDefaults`; no schema migration burden.
- NFR3 Fully accessible: keyboard-navigable, VoiceOver labels, Dynamic Type, WCAG-AA both themes (consistent with the rest of the app).
- NFR4 Honor the design system tokens — no raw literals; Settings reads as native macOS Settings (⌘,).
- NFR5 Security: never persist or transmit raw remote secrets from the UI; loopback-only assumption preserved; tunnel use is the user's responsibility, surfaced clearly.
- NFR6 Graceful degradation: 🚧 controls render as informative read-only/disabled with a one-line "needs engine support" note, never broken.

## 6. Engine contract dependencies (for the engine backlog)
The user's sync+backup goal is only partially reachable today. To fully satisfy C2–C4 the engine would need to:
- Expose configured **remotes** (backup + sync peers + merge-authority role) in the read-only settings view (for display).
- Add a **settings/config write capability** to set sync peers, backup target, and merge authority, with the same startup validation, and auth via `Secrets` references (no raw secrets over the API).
- Add **action** endpoints: "sync now", "backup now", and possibly "reindex".
These are engine-repo asks, NOT UI work. Until they exist, the Sync/Backup panel is **view-only** (C1 is the live part).

## 7. User stories (representative, with acceptance criteria)
- US-1 (A1–A3) *As the user, I can change the engine endpoint and confirm it connects.*
  AC: editing host:port + "Test" shows pass/fail; on save the app reconnects and the toolbar pill reflects the new state; value survives relaunch.
- US-2 (B1) *As the user, I can start/restart/stop the engine from Settings.*
  AC: each action runs the right `launchctl` call; the connection state transitions accordingly; failures show a clear message (e.g. agent not installed).
- US-3 (C1) *As the user, I can see whether multi-host sync is healthy.*
  AC: when `metrics.sync` is present, the panel shows role + last head + conflict count; when absent, it shows "sync not active"; surfaced conflicts are listed.
- US-4 (D1) *As the user, I can switch theme to Light or Follow System.*
  AC: the whole app re-themes live via tokens, both themes pass WCAG-AA, choice persists.
- US-5 (E1) *As the user, I can turn on autosave.*
  AC: edits persist after the debounce without ⌘S; a stale write still surfaces the 3-way merge (never silent overwrite).

## 8. Open questions (need user / engine decision)
1. Endpoint: single global value, or full named **profiles** (A4) in v1?
2. Sync/backup config (C3): is the engine willing to add a write endpoint, or is **config-file-only + UI read-only** acceptable for v1?
3. Theme: ship Light/System now, or stay dark-only and defer?
4. Should "switch vault" (multiple local engine instances) be an explicit later milestone, or out of scope?
5. Remote auth (C3): SSH key vs token; confirm Keychain (`keychain:`) as the only store.

## 9. Suggested phasing (not a commitment)
- **v1 (all ✅/🔌/👁, no engine changes):** A1–A5, B1–B3, C1, D*, E*, F*, G*, H*, I1, J1, K*, L*.
- **v2 (after engine adds write/actions):** C2–C4, B4, "sync now/backup now", reindex.
- **later (optional):** connection profiles → multiple local vaults; shortcut rebinding (J2).
