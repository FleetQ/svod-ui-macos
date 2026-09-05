# Design — Palette borrow sprint (agent-change review · HTML preview · pinned notes)

Source: `claudedocs/research_palette-team_2026-09-05.md`. Operator asked for all ideas judged worth borrowing, planned and implemented autonomously (2026-09-05). Scope is **app-only** (svod-ui-macos); no engine change, no contract bump.

## Forcing questions

**Who needs this? What are they doing today?**
One person running several MCP agents (claude-code, claude-desktop, lm-studio) that write into the personal vault unattended. Today an agent write is a commit the moment it happens; the only trace is a live row in the Inspector's per-note activity card (visible only while that note is open, only while the app was running) and the History pane if you already know which note to look at. There is no answer to "what did the agents change while I was away" short of `git log` in the vault.

**Narrowest MVP someone would pay for?**
A persistent list of unreviewed agent commits with one-click jump to the diff, a ✓ to dismiss, and a Revert that restores the pre-commit content as a new commit. That is Palette's save-back review, applied after the fact instead of before, which is the right shape for a single-user vault where agents are first-class writers.

**What makes someone say "whoa"?**
Opening the app after a night of agent runs and seeing "7 agent changes to review" on the Inspector button, clicking through each diff in seconds, reverting the one that overwrote a decision log. And an agent-written `.html` report rendering as a page inside Svod instead of a wall of tags.

**How does it compound?**
Every agent write already lands in git with history; the review list makes that history *actionable* without changing the write model. Pinned notes and HTML preview lower daily friction: the notes you reach for every day are one click away, and agents can be asked for styled output because Svod can show it.

## Scope

| # | Feature | Where | Size |
|---|---|---|---|
| A1 | Agent-change review: persisted unreviewed list, jump-to-diff, mark reviewed, revert | `ActivityModel`, `InspectorView`, `HistoryModel/View`, `RootView` badge | M |
| A2 | HTML preview in the web editor (`.html`/`.htm`) via sandboxed iframe; auto-preview on open | `editor.src.js`, `editor.css`, `EditorView` | S |
| B3 | Pinned notes: per-vault pins, Pinned section above the tree, Pin/Unpin in the context menu | `SidebarModel`, `SidebarView` | S |

**Out (deliberate):** B4 prompts-in-vault (engine change, and the engine does not enforce agent prompts, so the home of the text barely matters), B5 vault templates, C6/C7. A heavy staging role (`WRITE_STAGED`) is rejected for now: Palette needs a sandbox because a team shares a folder; here post-hoc review over git history gives the same answer with zero engine surface.

## Decisions

- **Only agent commits are reviewable.** The engine tags MCP writes with `agentId` (both `agent.activity` and `commit.created`); App-API writes carry `author` = the UI author and no `agentId`; watcher commits have `author: "external"` and no path. `agentId != nil` is the criterion. Nothing the user wrote in the app lands in their own review list.
- **Pending list persists across launches** (UserDefaults, JSON of `SvodEvent`, cap 200). Events arrive only while the app holds the WebSocket, so the list is "since the app last ran with the socket open", not a full git log. Documented in the card's empty state. A vault-wide history endpoint would close that gap; not in this sprint.
- **Revert is refused when the file moved on.** Before writing, the model checks `history(path, max: 1).first.commit == event.commit`. If a later commit exists the row says "changed since" and offers History instead. Reverting blindly would drop the later edits too. A note *created* by the agent is reverted by moving it to `.trash/` (the engine's soft delete, restorable). `delete`/`move` commits get ✓ only.
- **Vault safety without vault tags.** MCP events carry no `vault`; revert runs against the active vault. The head-commit check makes a wrong-vault path fail closed (404 or a different head), never a wrong-file write.
- **HTML renders in a sandboxed iframe with `allow-scripts` only.** No `allow-same-origin`, so the document gets an opaque origin: no access to the editor page's DOM or `file://`. Scripts are allowed because Palette's use cases (decks, dashboards, prototypes) need them. Network is not blocked; an agent-written page may pull a CDN library. Content already passes through the same trust boundary as markdown (agents, synced sources).
- **The sandbox does NOT hide the WKWebView bridge.** Code review verified with a standalone WKWebView harness that `window.webkit.messageHandlers.svod` is injected into the sandboxed subframe too, so a `.html` note could post a `change` message and rewrite the open document as the user's own commit. The Swift handler therefore drops every message whose `frameInfo.isMainFrame` is false. This is the load-bearing control; the sandbox attribute is defence in depth.
- **Revert is an allowlist, not a denylist.** Only `write`, `edit` and untagged commits can be reverted. `promote` is a move whose event carries the destination path; its parent copy is absent, so a revert would have trashed the promoted note. `remember` can write two files in one commit.
- **A vault switch mid-revert aborts.** Each client call resolves the vault at call time; the model re-checks the active vault id after every await and refuses to write if it changed. Cross-vault inbox rows remain a known gap: MCP events carry no vault tag, so an agent commit from another vault opens against the active one. Tagging MCP events with their vault is an engine follow-up.
- **Pins wait for the vault id.** On launch the sidebar loads before the vault list resolves; reading or writing pins under a placeholder key would strand them, so pins are inert until the id is known and re-read when it resolves.
- **The inbox says what it covers**: "commits made while the app was connected". The engine keeps no event replay, so anything committed while the app was closed or reconnecting is not in the list.
- **Pins are personal and per vault**, like Palette's shortcuts: `svod.sidebar.pinned.<vaultId>`. Pins whose file no longer exists in the tree are hidden, not deleted, so a note restored from trash reappears pinned.
