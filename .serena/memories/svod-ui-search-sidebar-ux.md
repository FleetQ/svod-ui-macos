# Svod UI — search palette + sidebar reveal UX (v0.2.6 / v0.2.7, 2026-07-03)

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

## Release cadence facts
- Version bump pattern: sed both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (2 occurrences each) in project.pbxproj, separate `build(macos): bump` commit, then `PUBLISH=1 Scripts/release.sh <ver> <build>` in background with output redirected to `build/release-<ver>.log` (never pipe — SIGPIPE gotcha in `mem:svod-ui-release-signing`).
- v0.2.6 (build 8) and v0.2.7 (build 9) both published; /Applications may lag behind until Sparkle updates or a manual DMG install.
