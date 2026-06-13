# Svod UI (macOS)

A native macOS client (SwiftUI) for the [Svod engine](https://github.com/FleetQ/svod-engine) — a calm, dark-first reader/editor for a git-backed, multi-vault, multi-agent knowledge base you can read, diff, and restore.

The client lives in its own repo and is released independently of the engine; the two are
decoupled by a versioned OpenAPI contract (see
[ADR-0002](https://github.com/FleetQ/svod-engine/blob/main/docs/adr/0002-repo-split-and-license.md)).

## What it is

A three-pane shell — **sidebar · editor · inspector** — over a running Svod engine. It is a
thin client: **zero JVM**, no local database; all state lives in the engine and it talks over
HTTP/JSON + WebSocket only.

### Features

- **Multi-vault** — switch the active vault from the toolbar (per-vault sync status, default
  flagged); the whole app re-scopes. Import an Obsidian vault (folder → engine import →
  imported/unchanged/skipped).
- **Editor** — live-rendered markdown (inline, not split-preview), `[[wikilink]]` autocomplete
  with hover preview, qualified cross-vault `[[vault:note]]` links, and a foldable frontmatter
  property panel.
- **Search (⌘K)** — hybrid BM25 + semantic results with snippet highlights and filter chips;
  an "all vaults" toggle for federated search (results tagged with their vault).
- **Graph** — force-directed, local/global, scoped to the active vault.
- **History & conflicts** — per-file timeline, responsive side-by-side / unified diff, one-click
  restore, and a 3-way merge UI (base / ours / theirs) that resolves conflicts without ever
  touching git.
- **Inspector** — backlinks, cross-vault backlinks (jump across vaults), recent history, and
  live per-note agent activity.
- **Live & calm** — a WebSocket-driven agent activity feed; engine updates animate in gently.
- **Engine lifecycle** — connected / starting / disconnected states and a one-button
  **Start Svod**.
- **Settings (⌘,)** — endpoint, appearance (dark-first, with light), editor, search, activity,
  graph, and sync/backup.

Accessibility is a first-class goal: full keyboard navigation, VoiceOver labels, Dynamic Type,
and WCAG-AA contrast in both themes.

## How it talks to the engine

It speaks only the engine's **App API** (loopback `http://127.0.0.1:7517` HTTP/JSON + a
WebSocket at `/api/v1/events`), defined by the published **OpenAPI contract** in
`svod-engine/contract/openapi.yaml` (currently **v0.3.0**). The contract is the single source
of truth; this client is built against it and is swappable. The engine and this UI are
released independently. The App API is loopback-only and has no per-client auth — agent access
goes through the engine's MCP surface, not this UI.

## Build & run

Requires **Xcode 16+** and **macOS 14+**.

```sh
# Build from the command line
xcodebuild -project Svod.xcodeproj -scheme Svod -configuration Debug \
  -destination 'platform=macOS' build
```

or just open `Svod.xcodeproj` in Xcode and run.

The app connects to a locally running engine on `127.0.0.1:7517`. Start one with the engine's
one-button launchd label:

```sh
launchctl kickstart -k gui/$(id -u)/dev.svod.engine
# then poll GET /ready until {"ready":true}
```

For a multi-vault setup, run the engine from source against a multi-vault config (see
`svod-engine/dist/config.sample.multivault.json`), and point the client at a non-default
endpoint from **Settings → Connection** if needed.

> The project uses Xcode **file-system synchronized groups**, so adding a Swift file under
> `Svod/` never edits `project.pbxproj`.

## Layout

```
Svod/
  DesignSystem/   design tokens (color, spacing, type, motion) + base components
  Networking/     SvodClient protocol + DTOs (mapped from the OpenAPI contract),
                  LiveSvodClient (URLSession + WebSocket), MockSvodClient (canned 2-vault data)
  App/            SvodApp, RootView (3-pane shell), AppModel + one sub-model per feature
  Features/       Editor, Search, Graph, History, Sidebar, Activity, Inspector, Vaults,
                  Import, Engine, Settings
```

`MockSvodClient` ships canned multi-vault data (two vaults, a base/ours/theirs conflict,
cross-vault backlinks), so every view builds and previews in Xcode without a running engine.

## License

TBD — tracked separately from the engine. The engine is Apache-2.0 (proposed).
