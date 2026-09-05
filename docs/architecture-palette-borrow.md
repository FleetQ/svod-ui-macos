# Architecture — Palette borrow sprint

Reads `docs/design-palette-borrow.md`. All changes in svod-ui-macos; the frozen `SvodClient` contract is untouched (every call used already exists: `history`, `revision`, `readFile`, `writeFile`, `deleteFile`).

## A1 — Agent-change review

### Data flow

```
WS event ──▶ EngineModel.startEventStream ──▶ ActivityModel.ingest(event)
                                                 ├─ feed (existing, in-memory)
                                                 └─ pending (NEW, persisted)  ──▶ UserDefaults "svod.activity.pending"
InspectorView.reviewCard ◀── app.activity.pending
   row tap   ──▶ app.open(path) + history.focusCommit = commit + setCenter(.history)
   ✓         ──▶ activity.markReviewed(event)
   Revert    ──▶ activity.revert(event)  ──▶ history(path,1) ▶ revision(commit~1) ▶ readFile ▶ writeFile(expectedRevision)
                                            │                                     └─ 409 ▶ app.presentConflict
                                            └─ parent missing ▶ deleteFile(expectedRevision)  (note created by agent → trash)
RootView inspector button ◀── ReviewBadge(activity) shows pending.count
```

### `ActivityModel` (App/ActivityModel.swift)

```swift
public init(client: SvodClient, defaults: UserDefaults = .standard)
@Published public private(set) var pending: [SvodEvent]      // newest first, cap 200, persisted
public func ingest(_ event: SvodEvent)                        // existing; additionally calls trackPending
public func markReviewed(_ event: SvodEvent)
public func markAllReviewed()
public enum RevertOutcome: Equatable { case reverted, trashed, changedSince, conflict, failed(String) }
public func revert(_ event: SvodEvent) async -> RevertOutcome
public static func isReviewable(_ event: SvodEvent) -> Bool   // agentId != nil && commit != nil && type ∈ {agentActivity, commitCreated}
public static func canRevert(_ event: SvodEvent) -> Bool      // isReviewable && tool ∉ {delete, move}
```

- `trackPending` dedupes by commit (its own set, independent of the feed's filter settings, so a hidden feed type still lands in review), inserts at 0, trims to cap, persists.
- Persistence: `JSONEncoder` of `[SvodEvent]` (already `Codable`) under `svod.activity.pending`; loaded in `init`; decode failure ⇒ empty list.
- `canRevert` is an allowlist: tool ∈ {nil, `write`, `edit`}.
- `revert` captures the active vault id first and re-checks it after every await (`.failed` if it changed — nothing written). Steps, in order, each mapped to an outcome:
  1. `guard canRevert` else `.failed("not revertible")`.
  2. `history(path, max: 1)` — if `first?.commit != commit` ⇒ `.changedSince` (list row keeps the item, shows the hint).
  3. `revision(path, "\(commit)~1")`: `badRequest`/`notFound` ⇒ parent has no copy of the file ⇒ agent created it ⇒ `readFile` then `deleteFile(path, expectedRevision:)` ⇒ `.trashed`, and `app.refreshActiveVault()`.
  4. Otherwise `readFile` ⇒ `writeFile(path, old.content, expectedRevision: current.revision)`; `.conflict(body)` ⇒ `app.presentConflict(body)` ⇒ `.conflict`; success ⇒ `.reverted`.
  5. On `.reverted`/`.trashed` the event is removed from `pending`.

### `HistoryModel` / `HistoryView`

- `@Published var focusCommit: String?` and `focusMissing: String?` on the model. After a load, `selectAfterLoad()` selects the requested commit when present; otherwise it selects the newest and sets `focusMissing`, which the diff toolbar shows as a caption ("isn't in the last 100 revisions") instead of silently substituting. When the jump targets the note whose timeline is already on screen (no task-id change), `HistoryView.onChange(of: model.focusCommit)` calls `applyFocus()`.

### `EditorModel`

- `applyAutoPreview(path:)` runs at the end of a successful `load`: an `.html` file turns preview on and remembers it did (`autoPreviewed`); the next non-html load turns it back off only in that case. `togglePreview()` (the toolbar) clears the flag so a mode the user chose survives. Lives in the model because the editor view is torn down on every center-pane switch.

### `WebEditorView.Coordinator`

- `userContentController(_:didReceive:)` drops any message with `frameInfo.isMainFrame == false`. The bridge handler is injected into every frame, sandbox or not.

### `InspectorView`

- New `reviewCard` rendered first in both branches (selection and no-selection), only when `pending` is non-empty. `@ObservedObject var activity` obtained from `app.activity` in a child view `ReviewCard(activity:)` so the Inspector body does not re-render on every feed event.
- Row: identity dot (`ThemeColor.agentColor`), `agentId`, verb, filename, relative time, and a trailing ⋯ with **Mark reviewed** / **Revert…** (confirm alert). Row tap = jump. Header has **Mark all reviewed**.
- Outcome feedback: `.changedSince` ⇒ inline caption under the row ("Changed since — open History"), `.failed` ⇒ caption with the message. No modal beyond the revert confirmation.

### `RootView`

- The inspector toolbar button gets `.overlay(alignment: .topTrailing) { ReviewBadge(activity: app.activity) }`; the badge is its own `@ObservedObject` view and renders nothing at count 0. This is the only edit to the shell.

## A2 — HTML preview

### `tooling/webeditor/editor.src.js`

- `HTML_EXTS = new Set(["html", "htm"])`, `isHtmlFile(name)`.
- `renderPreview()`: html branch **before** the code branch — clear `#preview`, toggle class `html` on it, append `<iframe class="html-preview" sandbox="allow-scripts">` with `srcdoc = text`. Non-html branches remove the class.
- Edit pane: unchanged (language-data already resolves `.html`; `makeTheme()` already treats non-markdown as code).

### `Svod/Resources/webeditor/editor.css`

- `#preview.html { max-width: none; padding: 0; }` and `#preview iframe.html-preview { width: 100%; height: 100%; border: 0; background: #fff; display: block; }`. A white background is deliberate: the page's own CSS decides its look; a dark editor surface behind a white-less page would render as unreadable black-on-transparent.

### `EditorView`

- After `model.load(path:)` in the `.task(id: app.selectedPath)`: if the path is html and preview is off, turn preview on and remember `autoPreviewed = true`; when a later path is not html and `autoPreviewed`, turn preview off and clear the flag. A user toggle in between is respected (flag cleared on manual toggle is unnecessary: we only turn preview *off* when we were the ones who turned it on and the file type changed).

### Build

- `cd tooling/webeditor && npm run build` regenerates `Svod/Resources/webeditor/editor.bundle.js` (committed artifact). Verify via the http-harness recipe from `mem:svod-ui-webeditor-file-types`.

## B3 — Pinned notes

### `SidebarModel`

```swift
public init(client: SvodClient, defaults: UserDefaults = .standard)
@Published public private(set) var pinned: [String]           // vault-scoped, persisted
public func togglePin(_ path: String)
public func isPinned(_ path: String) -> Bool
public var pinnedNotes: [String]                              // pinned ∩ files in `tree`, pin order
```

- Key `svod.sidebar.pinned.<vaultId>` with `vaultId = app?.vault.activeVaultId ?? "default"`; `load()` reloads pins (it already runs on vault switch via `reloadEpoch`). `pinnedNotes` walks the tree once per access; the tree is ≤ ~4k nodes and the section renders only when pins exist.

### `SidebarView`

- Notes tab: `pinnedSection` inside the scroll above `fileTreeSection`, shown when `pinnedNotes` is non-empty and no text/theme filter is active. Rows are `ListRow(title: filename, subtitle: parent folder)` with a `pin.fill` icon, tap ⇒ `app.open`, context menu **Unpin**.
- `TreeNodeRow` file context menu gains **Pin** / **Unpin** between Open and Copy Path.

## Files touched

| File | Change |
|---|---|
| `Svod/App/ActivityModel.swift` | pending list, persistence, revert |
| `Svod/App/HistoryModel.swift` | `focusCommit` |
| `Svod/Features/History/HistoryView.swift` | honor `focusCommit` |
| `Svod/Features/Inspector/InspectorView.swift` | review card |
| `Svod/Features/Activity/ReviewCard.swift` | NEW: card + rows + badge |
| `Svod/App/RootView.swift` | badge overlay on inspector button |
| `Svod/App/SidebarModel.swift` | pins |
| `Svod/Features/Sidebar/SidebarView.swift` | pinned section, context menu |
| `Svod/Features/Editor/EditorView.swift` | auto-preview for html |
| `tooling/webeditor/editor.src.js`, `Svod/Resources/webeditor/editor.css`, `editor.bundle.js` | html preview |
| `SvodTests/ActivityReviewTests.swift`, `SvodTests/SidebarPinsTests.swift` | NEW |
