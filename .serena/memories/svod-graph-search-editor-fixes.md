# Svod UI — graph / search / editor fixes (session 2026-06-15)

Engine companion repo: ~/htdocs/svod (FleetQ/svod-engine). App API on **127.0.0.1:7619** (NOT 7517). See `mem:svod-engine-deploy-gotcha` — committed engine changes need manual `installDist` + `launchctl kickstart -k gui/$UID/dev.svod.engine` to go live. Current: engine **v1.3.0**, contract **0.10.0**.

## Contract progression this session
- 0.8.0 pluggable embedders; 0.9.0 `POST /api/v1/embedder/models` (enumerate provider models); 0.10.0 filter-only tag search + reranker exposed in /settings.

## Embedder model dropdown (contract 0.9.0)
- `POST /api/v1/embedder/models` body = EmbedderRequest → `{provider, models:[{id, dimension?}]}`. Empty list = can't enumerate → UI falls back to manual text field.
- UI: `IndexingSettingsView` editable Picker + "Custom…"; Ollama ids carry `:latest` → normalize with a `:latest`-stripping compare so the active model isn't shown as "(custom)".

## Graph (Features/Graph/) — perf + interaction
- `GraphScene` is `@MainActor`; the redraw loop was running the **O(n²) physics on the main thread** → jank. Fixed by `Task.detached` doing `local.step()` off-main, pushing snapshots back via a @MainActor `applySnapshot`. Reheat across the actor boundary via a `reheatRequested` flag.
- Force-balance + damping ALONE never converges in a dense graph (overlap impulses keep injecting motion) → perpetual drift. Real fix = **d3-style alpha cooling** in `GraphLayout`: per-step displacement scaled by `alpha`, `alpha *= (1-alphaDecay)` toward `alphaMin`; settle when `alpha <= alphaMin`. Energy-threshold settling is WRONG (energy = sum over nodes, scales with N).
- **Orphan separation**: only nodes with degree ≥ 1 are simulated (`simulatedCount`, connected nodes sorted first); degree-0 orphans get a static peripheral spiral halo, drawn dim + label-free. Cuts O(n²) and clutter.
- **Viewport culling** in `draw()` (skip off-screen nodes/edges/labels) → smooth zoom; labels never drawn in bulk for orphans.
- **Mouse scroll-wheel zoom**: SwiftUI has no scroll modifier on macOS → `NSEvent.addLocalMonitorForEvents(.scrollWheel)` gated on `scene.pointerInside` (set from `onContinuousHover`), anchored on cursor by recomputing `pan` from a stored `pointer`+`viewCenter`. `import AppKit` in GraphView.

## Editor white flash
- WKWebView default backing is white; before editor.css paints it flashed on note open. Fix: `wv.setValue(false, forKey: "drawsBackground")` (transparent) so the dark SwiftUI surface shows through. Keep `underPageBackgroundColor`. (Persisting the WKWebView across notes via overlay was tried and REVERTED — content stopped pushing reliably; recreation + transparent bg is the working approach.)

## Sidebar selection
- Row bg was driven by per-row `@FocusState` → every clicked row stayed highlighted (button focus not cleared exclusively in the recursive tree). Fix: bg = `isSelected` (open note) + transient `.onHover`, drop focus from bg.

## Wikilinks
- Resolution: prefer engine `/file/links` `resolved`, but that call is SLOW (link-heavy notes ~8s) and loads async → links didn't navigate. Added fallback in `EditorModel.resolvedPath` via `notePaths` (Set of all paths from the tree, loads faster): `target(.md)` exact, then bare-name lastPathComponent match.
- Editor preview: `[[target|alias]]` inside GFM tables broke (table tokenizer splits on `|` before the inline rule). Fix in `tooling/webeditor/editor.src.js`: `protectWikilinkPipes` swaps the alias `|` to a U+F8FF sentinel before `md.render`, restored in the wikilink rule. Rebuild bundle: `cd tooling/webeditor && npm run build` (esbuild, ~5MB).

## Search / browse-by-tag
- Engine search returns **per-chunk/per-heading hits** → a note appears many times (tag=laravel count 2 → 56 hits across 2 unique paths). UI must **dedupe by note** (`SearchModel.collapsedByNote`, best score per `vault:path`).
- Browse-by-tag: engine 0.10.0 supports filter-only (`?tags=…` no/empty `q`). Client: relaxed the `!q.isEmpty` guard to also allow `filterTags`/`pathPrefix`; `selectTag` now sets filterTags + clears query + calls `search()`.
- `CommandPaletteView.resultsSection` gated on `query.isEmpty` → showed idle prompt even with tag results (footer said "1 result", body empty). Fix: show `resultsList` whenever `!results.isEmpty`; idle only when no query AND no filters AND nothing searched.

## Pending engine-side (handed off, may be done)
- Faster `/file/links` (was ~8s; v1.2.4 incremental index → ~545ms warm, ~10s cold).
- Tag filter correctness confirmed OK in v1.3.0 (per-chunk hits are expected; dedupe is the UI's job).

All UI work merged to `main` across PRs/merges: embedder-model-dropdown, index-md-links, graph-perf-editor-polish, wikilinks-tag-browse, + tag-results-display (pending commit at session end).
