# Svod UI — startup note restore, properties default, code preview (2026-08-28)

Shipped as **app v0.2.20 (build 22)** and **v0.2.21 (build 23)**, both notarized and installed.
Touches `AppModel`, `SettingsStore`, `FrontmatterPanel`. Extends [[svod-ui-settings]] (whose
"Startup (reopenLastNote, lastOpenedPath)" line is now incomplete — see below).

## 1. "Something went wrong / Not found." on every launch — a path remembered WITHOUT its vault

**Symptom:** the editor pane showed the error state immediately after launch, before touching
anything. Easy to misread as "no file is selected" — it is the opposite. `EditorView.swift`
renders `EmptyStateView("No note open")` when `selectedPath == nil`; an *error* means a path IS
selected and the engine answered 404.

**Reproduced against the live engine — the whole diagnosis in two calls:**

```
GET /api/v1/file?path=sales-and-marketing/socialscore-solution-documentation-6-25.md
   (no ?vault= ⇒ engine default = personal) → 404
   ?vault=socialscore                        → 200
```

**Two compounding causes in `AppModel.bootstrap()`:**

1. `settings.lastOpenedPath` was a **single global string with no vault qualifier**, while
   `open(path:)` wrote it for a note in *any* vault. The active vault is not persisted at all, so
   every launch resets to the engine default (`personal`) while the remembered path can belong
   to any vault.
2. The restore was **synchronous, before `await vault.load()`**. Even with the right vault
   persisted, `EditorView`'s `.task(id: app.selectedPath)` fires the moment the path is set — the
   client's active vault is still unset at that point.

**It never self-healed.** `EditorView` has a `reloadEpoch` retry for exactly this class of race,
but `reloadEpoch` is only bumped by `didSwitchVault()` / `refreshActiveVault()`, and
`VaultModel.load()` *keeps* a still-valid selection without bumping it. So the error sat there
until the user pressed "Try Again" — which also failed, because the vault was genuinely wrong.

**Fix:** `settings.lastOpenedVault` records which vault the path belongs to; the restore moved
into the `Task` **after** `await vault.load()` (`reopenLastNoteIfPossible()` — switch vault first,
then set `selectedPath`). A remembered path with **no** remembered vault (an older build, or a
vault since deleted) is **dropped**, not opened against the wrong vault: the empty state beats a
404, and the next note the user opens re-arms the setting.

**The lesson:** an identifier that is only unique *within* a scope must be persisted *with* that
scope. `lastOpenedPath` was correct for a single-vault app and silently became a half-key when
multi-vault landed — no compile error, no test, and the failure only shows on a cold start whose
last note happened to live outside the default vault. Same family as [[wrong-subject-numbers]]:
the value was right, the subject it was resolved against was not.

## 2. Frontmatter "Properties" panel — collapsed by default, and it remembers

`FrontmatterPanel.swift` used `@State private var expanded = true`: the panel opened on **every**
note, pushing the body down by the height of every modeled property, and the state reset per note.
Now `@AppStorage("editor.propertiesExpanded") private var expanded = false` — collapsed by
default, and the user's last toggle persists across notes and launches. Same idiom as
`@AppStorage("history.diffLayout")` in `DiffView`. The header still shows the note title while
collapsed.

## 3. Code blocks that render as centered prose are a CONTENT problem, not a renderer one

The preview **already has full syntax highlighting** and did all along:
`tooling/webeditor/editor.src.js` runs markdown-it with a `highlight()` hook into **highlight.js**
(plus a `mermaid` branch), the edit pane uses `@codemirror/lang-markdown` with
`codeLanguages: languages`, and a whole non-markdown file is highlighted by extension.
`editor.css` themes the hljs token classes to the Svod palette.

What *looked* broken was a **Google Docs export**: in
`~/Svod/socialscore/product/socialscore-api-reference-v2.md` the code is not a fenced block but a
**one-cell markdown table with centre alignment**:

```
|  |
| :-: |
| import requests response = requests.post(    "https://api...
```

That explains every symptom at once — centred text (`:-:`), proportional font (`td`, not `pre`),
all newlines flattened into one paragraph, and `phone\_number` / `\[` / `\>` because Docs escaped
the underscores. No markdown renderer will highlight that.

**Before bulk-converting such a file:** only ~9 of the 20 single-column tables in it are code; the
rest are callout boxes (`**⚠️ Fraud Score scale is inverted**`), and the multi-column ones are real
tables that merely lost their header. Blind fences would destroy them.

## Verification that actually held

Both releases were verified the way [[svod-ui-release-signing]] insists — the **tag on the remote**
and the **enclosure URL**, never the script's exit code: `git ls-remote --tags` shows
`refs/tags/v0.2.21`, `gh release view --json isDraft` is `false`, the enclosure is `200` with
`content-length` **equal to the `length=` in the live appcast**, and the installed bundle reports
`0.2.21 / 23` with `spctl` → `accepted, source=Notarized Developer ID`.

The startup fix was verified **on the running app**, not by reading the diff — two launches:
without `lastOpenedVault` → "No note open"; with `lastOpenedVault=socialscore` → the vault switches
and the note opens. 12/12 app tests pass (counted from the log, per [[kotlin-junit-silent-skip]]'s
rule about never trusting a "SUCCEEDED" banner).

**Not unit-tested, deliberately:** `SettingsStore` hardcodes `UserDefaults.standard` and the test
host shares the app's defaults domain (`dev.svod.Svod`), so a test would clobber the real user's
settings. Making it injectable is a refactor, not part of this fix. Recorded here so the gap is
visible rather than implied.
