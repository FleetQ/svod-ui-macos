# Test plan — Markdown rendering fixes

No XCTest target in this project; "test" = build green + live visual verification
against real imported notes (AGENTS.md headings/code/links/list; Servers.md tables).

## Build gate
- `xcodebuild ... build` green, zero source warnings.
- SwiftUI Previews still compile (EditorView previews).

## Visual checks (live engine on :7619, app pointed there)
1. **Prose font:** body paragraphs render in a proportional font (NOT monospace);
   code fences + inline code + tables stay monospace.
2. **Headings:** proportional bold/semibold, scaled by level, `#` markers dimmed.
3. **Markdown links:** `[tolaria](https://…)` shows "tolaria" as a link with the
   `(url)` dimmed; clicking opens the browser.
4. **Wikilinks:** `[[note]]` / `[[vault:note]]` still colored by resolution / cross-vault.
5. **Task lists:** `- [ ]` and `- [x]` checkbox tokens colored; done line dimmed+struck.
6. **Strikethrough:** `~~text~~` struck, `~~` dimmed.
7. **Images:** `![alt](url)` alt styled, syntax dimmed (no raw noise; no crash).
8. **Emphasis:** **bold** / *italic* / _italic_ apply on the proportional base.

## Edge cases
- A line that is both a list item and contains a link / inline code.
- `[x]` uppercase `[X]` accepted.
- Link whose text contains `]`-free brackets only (regex bounds).
- Image inside a list item.
- Empty alt `![](url)`.
- No regression on frontmatter panel, autocomplete popover, hover preview.

## Acceptance
All 8 visual checks pass on AGENTS.md + Servers.md; build green; no regression in
the editor (typing, autocomplete, cross-vault links still work).
