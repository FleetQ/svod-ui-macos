# Test plan — Palette borrow sprint

Runner: `xcodebuild test -project Svod.xcodeproj -scheme Svod -destination 'platform=macOS' -derivedDataPath build/dd`. Suite today: 12 tests. Every new test is verified **negatively** (revert its subject, watch it fail) before the MR, per `mem:svod-hardening-sprint-2026-08-17`.

## A1 — Agent-change review (`SvodTests/ActivityReviewTests.swift`)

Uses `MockSvodClient` plus an isolated `UserDefaults(suiteName:)` per test (removed in `tearDown`).

| # | Case | Expect |
|---|---|---|
| 1 | ingest `agent.activity` with `agentId` + `commit` | appears in `pending` (count 1) |
| 2 | ingest `commit.created` for the same commit | still count 1 (dedupe by commit) |
| 3 | ingest `commit.created` with `author` but no `agentId` (UI write) | not in `pending` |
| 4 | ingest `commit.created` with `author: "external"`, no path | not in `pending` |
| 5 | feed filter `showAgentActivity = false` | still lands in `pending` (review is independent of feed filters) |
| 6 | `markReviewed` | removed; persisted list on a fresh model over the same suite is empty |
| 7 | persistence round-trip | new `ActivityModel(defaults:)` over the same suite loads the pending item |
| 8 | cap | 201 distinct commits ⇒ 200 kept, newest first |
| 9 | `canRevert` | false for `tool: delete` / `move`; true for `write`, `edit`, nil |
| 10 | `revert` when history head ≠ event commit | `.changedSince`, item stays pending, no write |
| 11 | `revert` when head == commit and parent exists | `.reverted`, `writeFile` called with parent content and the current revision, item removed |
| 12 | `revert` when parent 400s | `.trashed`, `deleteFile` called, item removed |
| 13 | `revert` when write 409s | `.conflict`, `app.activeConflict` set, item stays |

Tests 10–13 use a `RecordingClient: MockSvodClient` subclass overriding `history`, `revision`, `readFile`, `writeFile`, `deleteFile` to script responses and record calls. `MockSvodClient` must be non-final for this.

## B3 — Pinned notes (`SvodTests/SidebarPinsTests.swift`)

| # | Case | Expect |
|---|---|---|
| 1 | `togglePin` twice | pinned then unpinned |
| 2 | persistence | fresh `SidebarModel(defaults:)` reads the pin back |
| 3 | per-vault key | pins written under vault A are not visible under vault B |
| 4 | `pinnedNotes` | a pin whose path is not in the tree is hidden, pin order preserved |

## A2 — HTML preview (manual, browser harness)

No JS test runner in the repo. Verify with the recipe from `mem:svod-ui-webeditor-file-types`:

1. `cd Svod/Resources/webeditor && python3 -m http.server 8932 --bind 127.0.0.1`, open a harness page in Chrome that loads `editor.bundle.js?v=<n>`.
2. `SvodEditor.setLanguage("reports/x.html")`, `setContent("<h1>Hi</h1><script>document.body.append('js ran')</script>")`, `setMode("preview")`.
3. Assert: `#preview iframe.html-preview` exists, `sandbox` attribute is exactly `allow-scripts`, `#preview` has class `html`; the iframe document contains `js ran` (scripts run) and `iframe.contentDocument` is `null` from the parent (opaque origin).
4. `setLanguage("notes/a.md")` + `setContent("# A")` ⇒ no iframe, `#preview` lost class `html`, `<h1>` rendered.
5. In the app: open an `.html` file ⇒ preview turns on automatically; switch to a `.md` ⇒ preview turns off; toggle preview manually on a `.md` then open `.html` ⇒ stays on.

## Regression

- Existing 12 tests still pass.
- Build has zero new warnings (`xcodebuild build` output grepped for `warning:` in `Svod/`).
- Inspector with no selection still shows its empty state when there is nothing to review.
- History pane with `focusCommit` nil behaves exactly as before (selects the newest commit).
