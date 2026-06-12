# Svod UI (macOS)

A **personal** native macOS client (SwiftUI) for the [Svod engine](https://github.com/FleetQ/svod-engine).

> ⚠️ **Not a supported product surface.** This is a personal tool, kept in its own repo and
> explicitly **out of the Svod product's scope** — no cross-OS support, no marketing, no
> stability guarantees. The product is the engine; see
> [ADR-0002](https://github.com/FleetQ/svod-engine/blob/main/docs/adr/0002-repo-split-and-license.md).

## What it is

A three-pane reader/editor for a git-backed Svod vault — file tree, live-markdown editor,
inspector (backlinks, history, agent activity) — plus hybrid ⌘K search, graph view, and a
3-way conflict UI. It is a thin client: zero JVM, all state lives in the engine.

## How it talks to the engine

It speaks only the engine's **App API** (loopback HTTP/JSON + WebSocket), defined by the
published **OpenAPI contract** in `svod-engine/contract/`. The contract is the single source
of truth; this client is built against it and is swappable. The engine and this UI are
released independently.

> The App API + contract land at **Step 4** of the engine build order, so this client cannot
> be fully wired up until then.

## Build

Requires Xcode (Swift 6.x). Open the project in Xcode and run against a locally-running Svod
engine. (Project scaffold to follow.)

## License

TBD — tracked separately from the engine. The engine is Apache-2.0 (proposed).
