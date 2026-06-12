# Svod macOS UI — architecture & conventions

Native SwiftUI macOS client for the Svod engine (HTTP/JSON + WebSocket only; **zero JVM**). Personal app, separate repo `FleetQ/svod-ui-macos`, working dir `~/htdocs/svod-ui-macos`. Aesthetic: calm, archival-yet-modern, content-first, **dark-first**.

## Build / project
- Xcode app `Svod.xcodeproj` using **`PBXFileSystemSynchronizedRootGroup`** (root = `Svod/`) → new files auto-join the target; `project.pbxproj` is never hand-edited. This is what made collision-free parallel work possible.
- **Unsandboxed** (no sandbox entitlement) so `Process` can run `launchctl kickstart`. `MACOSX_DEPLOYMENT_TARGET 14.0`, `SWIFT_VERSION 5.0`, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`.
- Build: `xcodebuild -project Svod.xcodeproj -scheme Svod -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build`. (`build/` is git-ignored.)

## Layers (FROZEN foundation — edit deliberately)
- `Svod/DesignSystem/` — tokens only, no raw literals: `ThemeColor` (dark-first WCAG-AA, dynamic NSColor provider via `dyn(dark:light:)`), `Spacing` (8pt grid), `Typography` (SF Pro/SF Mono, relative→Dynamic Type), `Radii`, `Motion` (springs). Components: Card, ToolbarSurface, StatusPill, ListRow, StateViews (Empty/Loading/Error/Offline), SvodButtonStyle. NB: `Theme` enum can't have a `Type` typealias (reserved) → it's `Typo`.
- `Svod/Networking/` — `SvodClient` protocol (every endpoint) + all DTOs hand-mapped from `~/htdocs/svod/contract/openapi.yaml`; `LiveSvodClient` (URLSession HTTP + WebSocket, status→`SvodClientError` mapping, 409→`.conflict(ConflictBody)`); `MockSvodClient` (`.preview/.offline/.empty`) for builds/previews without an engine. Events: `SvodEvent{type,ts(ms),data:EventPayload}` (`Events.swift`).
- `Svod/App/` — `AppModel` (`@MainActor ObservableObject` composition root: `selectedPath`, `connection:ConnectionState`, `latestEvent`, `activeConflict`, pane flags, `centerMode`) composing 7 sub-models; sub-models are teammate-owned files but live in `App/` (`EditorModel`, `SearchModel`, `GraphModel`, `HistoryModel`, `ActivityModel`, `SidebarModel`, `EngineModel`). `RootView` = NavigationSplitView + `.inspector`, 3-pane sidebar|center(editor/graph/history)|inspector, translucent toolbar, ⌘K overlay, conflict sheet. `FeatureSlots.swift` = integration seam → feature views. `SvodApp` injects `AppModel(client: LiveSvodClient())`, `.preferredColorScheme(.dark)`, ⌘K/⌘S/⌘1-3 commands.
- `Svod/Features/{Editor,Search,Graph,History,Sidebar,Activity,Inspector,Engine}/` — one folder per feature, each consumes the frozen contract read-only.

## Engine wiring (App API loopback `127.0.0.1:7517`)
- WS `/api/v1/events`; events `{type,ts,data}`; **dedupe agent.activity vs commit.created by `data.commit`**.
- `EngineModel` drives detect→`launchctl kickstart -k gui/<uid>/dev.svod.engine`→poll `/ready`→WS loop (backoff reconnect 1.6–8s).
- Diff a commit: `from=<commit>~1&to=<commit>`; fall back to `/file/revision` on first commit (parent 400s).
- Live `SvodEngine.app` at `~/htdocs/svod/dist/build/`; a `java` process listens on 7517.

## Contract gaps (do NOT invent engine behavior)
- `/api/v1/conflicts` returns only `{path, reasons[]}` (Step-7 sync stub) — full **3-way merge is only data-backed by the write-409 `ConflictBody`** (`expected`=base, `currentContent`=theirs, editor draft=yours). `client.conflicts()` is a list surface only.
- **Restore = write old revision content back as a new commit** (no restore-revision endpoint). `restoreFile` is only `.trash/` undelete.
- No date filter param on `/search`. Search response `mode` is UPPERCASE; request `mode` lowercase.
- Vault paths may be Cyrillic (e.g. `бележки/първа.md`) — `URLComponents` query encoding handles it.

## Icon
- `design/` is the source: `build-svg.py` (geometry generator) → `svod-icon.svg` (arch tile), `svod-keystone.svg` (mark), `svod-keystone-template.svg` (menu-bar black). `generate-icons.sh` renders the full AppIcon set (10 PNGs) + `StatusItemTemplate.imageset` via `rsvg-convert` (librsvg at `/usr/local/bin`). Concept: masonry arch + **illuminated amber keystone** (single source of truth); icon accent is warm amber, distinct from the UI's blue accent.
- **Dock icon caching gotcha**: after changing the icon, clear `$(getconf DARWIN_USER_CACHE_DIR)com.apple.iconservices*` + `killall Dock` + `lsregister -f <app>`; `lsregister` alone does NOT bust the icon cache.

## Verification facts
- Integrated build green, zero source warnings. DTOs validated against the **live engine** — all wire shapes match incl. Cyrillic. App launches, connects, holds the WebSocket without crash.
- Screen-recording TCC: `screencapture` returns a black frame from a non-GUI shell unless the controlling app has Screen Recording permission.

## How it was built
Foundation authored inline (sequential), then 5 feature teammates run **in parallel in manual git worktrees** (`git worktree add ../svod-wt-<x>`), each owning a disjoint `Features/<X>/` + its sub-model, octopus-merged back (clean, disjoint files). The built-in `isolation: worktree` agent hook was broken in this environment → provisioned worktrees manually.
