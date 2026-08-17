# Web editor — file types, language switching, and how to debug it

## Overview

The editing surface is a bundled CodeMirror 6 + markdown-it + mermaid app running in a `WKWebView`
(`Svod/Resources/webeditor/`, built from `tooling/webeditor/editor.src.js` by esbuild). It was
originally **hardwired to markdown**: every file went through `md.render` in preview and the
markdown grammar in the edit pane, because the bridge never told JS what kind of file it held —
`setContent(text)` took text only.

For a `.py`/`.php` file that meant markdown-it flowed source as *prose*: single newlines collapsed
into paragraphs and the file became unreadable. Fixed in **app v0.2.12** (2026-07-25).

Complements `mem:svod-ui-architecture` (layers) and `mem:svod-embeddings-webeditor` (the editor's
origin).

## Key Patterns

### The bridge now carries the file type

Swift → JS gained **`setLanguage(path)`**, pushed from `WebEditorView.Coordinator` in both
`pushAll()` and `sync()`, **before** `setContent` — otherwise a code file flashes through the
markdown renderer once. `EditorView.swift` passes `path: app.selectedPath`.

JS keys both panes off the extension. A file with **no** extension counts as markdown: that is the
boot state before Swift sends a path, and every vault note is markdown anyway.

- **Preview**: non-markdown renders as `<pre class="code">` through highlight.js (already bundled
  for fenced blocks; its aliases map extensions directly — `py`→python, `rs`→rust, `yml`→yaml).
- **Edit pane**: the grammar comes from `@codemirror/language-data` via
  `LanguageDescription.matchFilename`, swapped through a `langC` Compartment. Markdown notes now
  pass `codeLanguages: languages`, so fenced ` ```python ` blocks highlight in the *source* pane
  too — previously only in preview.

### Three non-obvious requirements

1. **A grammar alone changes nothing.** `makeHighlight()` originally defined only markdown tags
   (heading/strong/emphasis/link/quote/list/meta), so Python parsed but every token fell through
   unstyled. Code tags — keyword, string, number, comment, typeName, function, punctuation — must
   be in the `HighlightStyle` or "language loaded" still looks like plain text.
2. **Code needs a monospace face at full width.** The note theme's proportional font at a 760px
   reading measure makes source unreadable even when correctly highlighted. `makeTheme()` branches
   on file type; `setLanguage` reconfigures `themeC` when prose ⇄ code flips.
3. **`setContent` must refresh a visible preview.** Swift only calls `setMode` when the *mode*
   changes, so a note whose content arrives after the pane is already in preview keeps the previous
   — or empty — render. This is the invariant that made the editor look **completely blank**.

## File Locations

- `tooling/webeditor/editor.src.js` — source of truth; `npm run build` writes
  `Svod/Resources/webeditor/editor.bundle.js` (esbuild, IIFE, minified)
- `Svod/Features/Editor/WebEditorView.swift` — `NSViewRepresentable` + the bridge Coordinator
- `Svod/Features/Editor/EditorView.swift` — call site, passes `path`
- `Svod/Resources/webeditor/editor.css` — `#preview pre.code` + `.hljs-*` token colors

## Constraints

- **`@codemirror/language-data` costs ~1.07 MB** (bundle 5,276,605 → 6,344,461 B). esbuild inlines
  its dynamic `import()`s under `--format=iife`, so no real dynamic import survives and `file://`
  in WKWebView is fine — verified by grepping the bundle (the one remaining `import(` is inside a
  regex literal).
- **An empty `<pre class="code">` renders as a thin rounded rectangle** (surface + border +
  radius from `editor.css`). If the editor looks blank except for a small bar near the top, that
  is the tell that the preview rendered with an *empty document* — not that the web view failed.

### Debugging recipe (the WKWebView gives you no console)

Serve the editor over HTTP and drive the bridge from Chrome; it reproduces the exact Swift call
sequence (`configure` → `setLanguage` → `setContent` → `setNoteNames` → `setMode` → `setFocusMode`):

```bash
cd Svod/Resources/webeditor && python3 -m http.server 8932 --bind 127.0.0.1
# then in Chrome: window.SvodEditor.setLanguage(...) / setContent(...) / setMode("preview")
```

Three traps that cost real time here:

- **Serve the source tree, not the built `.app`.** `npm run build` writes only
  `Svod/Resources/webeditor/`; `…/Svod.app/Contents/Resources/` keeps the bundle from the last
  `xcodebuild`. Serving the `.app` silently tests a stale bundle.
- **Chrome caches `editor.bundle.js` across reloads.** A query param on `editor.html` does not bust
  it — copy `editor.html` to a harness that references `editor.bundle.js?v=<n>`.
- **When the app and the browser harness disagree, A/B against a `git stash`ed baseline** instead of
  theorising. That is what proved the blank pane was newly introduced rather than pre-existing.
  Note `git stash push -- <paths>` aborts entirely if any path is untracked/ignored (here
  `tooling/webeditor/package-lock.json`), leaving nothing stashed — check the result before
  concluding you tested a baseline.

## Last Updated

2026-07-25 (app v0.2.12, build 14)
