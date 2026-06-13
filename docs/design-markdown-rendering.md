# Design — Markdown rendering fixes

Sprint: 2026-06-13. Source: UI review of the live editor against real imported
Obsidian notes (AGENTS.md, Servers.md). Approach stays a **live inline
highlighter** over NSTextView (markup visible but dimmed) — not a split preview.

## Problem (who/what)
The user reads/edits prose notes imported from Obsidian. Today the editor renders
**everything in SF Mono**, standard `[text](url)` links show raw, task lists and
strikethrough aren't styled — so prose reads like a terminal README, not the
"calm, content-first, archival" surface the product promises.

## Decisions
1. **Body font → proportional** (system SF Pro). Monospace is reserved for code
   fences, inline code, and tables (where column/byte alignment matters). This is
   the headline fix; "fix all" implies switching off mono-everywhere.
2. **Standard markdown links** `[text](url)` are styled (link color + dimmed
   syntax/URL) and clickable (http(s) → browser). Images `![alt](url)` excluded
   from link matching and styled distinctly (no inline image render yet).
3. **Task lists** `- [ ]` / `- [x]` get a rendered feel while staying editable:
   the checkbox token is colored (done = green), and a done line is dimmed +
   struck. Markup stays visible (editor philosophy).
4. **Strikethrough** `~~text~~` applies a strike + dims the `~~` markers.
5. **Images** `![alt](url)` — alt styled, syntax/URL dimmed. Inline image preview
   is explicitly OUT (NSTextAttachment work, future).
6. **Tables** keep monospace (existing). True column alignment is OUT (needs a
   real grid render); noted as future.

## Out of scope (deferred, with reason)
- **Incremental highlighting.** `highlight()` restyles the whole storage per
  keystroke. Real but it's a perf optimization, not a rendering defect, and a
  correct range-based rehighlight must handle multi-line constructs (fences,
  tables) carefully — too risky to rush in this batch. Tracked for a follow-up.
- Inline image rendering, table grid layout — see above.

## "Whoa" / compounding
Prose that actually looks like prose makes the vault pleasant to live in daily;
clickable links + task checkboxes make imported Obsidian notes usable as-is.
