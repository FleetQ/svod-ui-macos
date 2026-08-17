# Svod UI — search palette + sidebar UX (v0.2.6 / v0.2.7 / v0.2.13; last updated 2026-08-07)

Two releases in one day, both signed+notarized+published via `Scripts/release.sh` (see `mem:svod-ui-release-signing`). Feed + DMG live-verified via GitHub API (raw.githubusercontent CDN caches ~5 min — verify appcast pushes through `api.github.com/repos/.../contents/appcast.xml?ref=main` with `Accept: application/vnd.github.raw`, NOT the raw URL).

## ⌘K palette internals (SearchModel + CommandPaletteView)
- **Debounce pre-existed**: 180ms in `SearchModel.search(debounce:)`; every keystroke/filter change cancels the pending `debounceTask`. Don't "add" one again.
- **Autofocus fix (0.2.6)**: `onAppear { fieldFocused = true }` alone is UNRELIABLE — the palette mounts via an animated transition (`.move(edge:.top)+opacity` in RootView's overlay) and the field isn't in the responder chain on the first tick. Fix = `.defaultFocus($fieldFocused, true)` + `DispatchQueue.main.asyncAfter(+0.08) { fieldFocused = true }` re-assert.
- **Inline folder scope (0.2.6)**: query `projects/account` → `splitInlineScope` parses at the LAST `/` → `pathPrefix="projects"`, term `"account"`; `projects/clientA/x` scopes to `projects/clientA`; trailing slash (`projects/`) browses the folder (empty term + prefix counts as active). Inline scope OVERRIDES the filter-bar pathPrefix field while present (`effectivePrefix = scope ?? pathPrefix`). A folder chip in the search field row (`model.inlineScope`) confirms the parse. Trade-off accepted: can't literal-search text containing `/` (alternative `in:folder` token syntax was considered and rejected as less natural).
- **Cancelled-search guard (0.2.6)**: when a newer search cancels an in-flight request, `runSearch`'s catch blocks `guard !Task.isCancelled else { return }` — otherwise the superseded request flashed an error and cleared results.

## Sidebar reveal-open-note (0.2.7)
- `SidebarModel.reveal(path)`: inserts every ancestor prefix (split on `/`, dropLast) into `expanded`, then sets `@Published revealTarget = path`.
- View side: `ScrollViewReader` wraps the Notes tab; `.onChange(of: model.revealTarget)` → `proxy.scrollTo(target, anchor: .center)`, then resets `revealTarget = nil`. Ordering is safe because onChange fires AFTER the expanded folders re-render, and the tree is a plain (non-lazy) VStack so `.id(node.path)` anchors (on each TreeNodeRow's `row`) always exist.
- Trigger: `scope`-icon button next to the refresh button in the NOTES header; `.disabled(app.selectedPath == nil)`. Works for any open source (search/wikilink/history) since it reads `app.selectedPath`.

## Sidebar tree filter + sticky header (v0.2.13, build 15 — 2026-08-07)

A filter field in the Notes tab, distinct from ⌘K: this one prunes the *tree in place*
(structure browsing), the palette does full-text search. Both live in `SidebarView.swift`;
`SidebarModel` was NOT touched — the filter is view `@State`, since nothing outside the
view needs it.

- `pruned(_:query:)` (recursive, view-private): file survives if its name matches; dir
  survives if it matches (then keeps its **whole subtree**, so you can browse into a hit)
  or if any descendant survives, in which case a copied node carries only surviving kids.
  `TreeNode` has a public memberwise init, so building the pruned projection is trivial.
- Matching = `localizedStandardContains` — case- AND diacritic-insensitive, which is what
  the Cyrillic vault paths need. Don't hand-roll `.lowercased().contains` here (the
  older `filteredTags` does; it predates this).
- ~~`TreeNodeRow.forceExpanded: Bool`~~ — **SUPERSEDED in v0.2.15, see below.** The original
  design force-expanded EVERY folder while filtering. That is what made typing laggy.
- `TreeNodeRow` now takes `autoExpand: Set<String>` →
  `isExpanded = autoExpand.contains(path) || model.expanded.contains(path)`. The persisted
  `expanded` set is still untouched and the tree snaps back on clear. Known cosmetic wart:
  ←/→ and the context-menu Collapse still mutate `expanded` with no visible effect while
  the filter is on (same as Finder/VSCode) — accepted.

## The tree-filter lag and its fix (v0.2.15, build 17 — 2026-08-14)

User-reported: "филтрирането в sidebar-а е много лагаво при писане". **Root cause was the
render count, not the string matching.** `pruned` returns a folder that matched by NAME
together with its whole subtree (deliberate — so you can browse into a hit), and
`forceExpanded` then drew that entire subtree open. The Notes tree is a **non-lazy VStack**
(required so `.id(node.path)` anchors exist for `SidebarModel.reveal`), so every keystroke
rebuilt every one of those rows.

Measured on the personal vault (**3,558 nodes**: 3,216 files / 342 dirs, max depth 7):

| query | rendered before | after | |
|---|---|---|---|
| `proj` | 3,113 | 17 | 183x |
| `o` | 3,484 | 23 | 151x |
| `s` | 3,365 | 65 | 52x |
| `e` | 3,450 | 69 | 50x |
| `readme` | 215 | 215 | 1x (matches FILES — no subtree to collapse) |

Fix: `FilteredTree { roots, autoExpand }`. Only folders that survived because a
**descendant** matched go into `autoExpand`; a folder matching on its own name returns early
from `pruned` without being recorded, so it keeps its subtree but renders **collapsed**.

**The pruning logic is unchanged** — the set of surviving nodes is byte-identical before and
after (verified per query against the live tree). Only how many are drawn at once changed.
If a future change touches `pruned`, re-verify that invariant, not just the row count.

**Remaining lever if it ever lags again:** `pruned` still runs ~3,558 `localizedStandardContains`
calls per keystroke. Cheaper than rendering but not free — the fix there is a debounce on the
filter field, or pre-folded name keys. Deliberately NOT done in v0.2.15: rendering dominated,
and adding a debounce blind would have been speculative.
- **Sticky header**: the NOTES header (label + reveal + refresh) moved OUT of
  `fileTreeSection` into its own `treeHeader`, which sits with `treeFilterField` and a
  Divider in the `VStack(spacing: 0)` ABOVE the `ScrollView` inside the existing
  `ScrollViewReader`. Padding note: rows inside the scroll get `Spacing.sm` from their own
  modifier + `Spacing.sm` from the scroll VStack = 16, so the pinned header needs
  `.padding(.horizontal, Spacing.lg)` to keep the label aligned. The `revealTarget`
  `.onChange` moved to the outer VStack — `proxy` is still captured, so scroll-to-reveal
  is unaffected.

## Debounce split: typing vs discrete actions (v0.2.14, build 16 — 2026-08-14)

`SearchModel.search(debounce: Duration = .milliseconds(180))` used to be the ONLY entry point, so
a tag-chip tap, a mode-picker change, a memory type/status pick, the all-vaults and show-hidden
toggles, and the Clear button all waited 180 ms before the request even started. A single click is
not a burst to collapse — the debounce there is pure dead time.

- New `SearchModel.searchNow()` = `search(debounce: .zero)`. **Routed through `search`, not
  straight to `runSearch`**, so a newer interaction still supersedes an in-flight one via
  `debounceTask`.
- Eight discrete call sites converted (`SearchFiltersBar` ×6, `CommandPaletteView` Clear,
  `SearchModel.toggleTag`). Only the two genuine TEXT inputs stay debounced: the ⌘K query
  (`CommandPaletteView.onChange(of: model.query)`) and the Path prefix field.
- **Typing deliberately keeps the full 180 ms.** Each distinct prefix is a cache MISS on the
  engine, costing a fresh ~112 ms query embedding for a string nobody will search again, and it
  occupies a slot in the engine's 256-entry LRU. Lowering the typing debounce would raise engine
  load AND pollute that cache — the opposite of the intent.

Context: this landed right after engine v1.14.0 added the query-embedding cache (repeat semantic
search ~157 ms → ~20 ms), which is what made a fixed 180 ms wait the dominant cost on repeats.

## GUI verification gotcha (cost real time)

Driving the app with `osascript … System Events click/keystroke` at screen coordinates is
**unreliable here** — a click meant for the sidebar landed in Chrome and brought it
frontmost, so the keystrokes went to whatever page was open. Dangerous shape: if focus had
been in the editor instead of a filter field, synthetic typing would have written into the
user's vault (checked after the fact: `git status` in `~/Svod/personal` was clean).
Prefer `screencapture` + reading the image for verification and let the USER type; don't
synthesize keystrokes into an app that can write to disk.

## Release cadence facts
- Version bump pattern: sed both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (2 occurrences each) in project.pbxproj, then `PUBLISH=1 Scripts/release.sh <ver> <build>` with output redirected to a log (never pipe — SIGPIPE gotcha in `mem:svod-ui-release-signing`). `release.sh` does NOT edit the pbxproj — it passes the versions as xcodebuild overrides — so the bump must be committed by you. A separate `build(macos): bump` commit is optional; v0.2.13 folded the bump into the feature commit and the release was clean. What IS load-bearing: **push main BEFORE `PUBLISH=1`**, because the script runs `gh release create` (which tags origin/main HEAD) before it commits the appcast — see `mem:svod-recall-memory-sprint`.
- v0.2.6 (build 8) and v0.2.7 (build 9) both published; /Applications may lag behind until Sparkle updates or a manual DMG install.
