# Retro — Markdown rendering sprint (2026-06-13)

Full `/sprint-orchestrate` run on the editor's markdown rendering, triggered by a
UI review against real imported Obsidian notes.

## Shipped (main, pushed — 9601e31)
- Proportional body font (mono only for code/inline-code/tables); proportional
  headings. The editor reads as prose, not a terminal — the headline fix.
- Standard `[text](url)` links styled + clickable (http→browser); `![alt](url)`
  images styled; task lists `- [ ]`/`- [x]` with colored checkbox (done=green,
  dimmed+struck); `~~strikethrough~~`.
- Review fix: wikilinks run before markdown links (nested-link clobber).

## Pipeline
Think (compressed — scope clear from review; the one product call, body font →
proportional, taken by default) → Plan (design/architecture/test-plan docs) →
Build (2 files) → Review (1 reviewer agent: 1 real finding fixed, 1 false-positive
analyzed & documented) → Test (build green + live visual on AGENTS.md) → Ship
(FF-merge + push) → Reflect.

## What went well
- The review-first ordering caught the wikilink/markdown-link overlap before test.
- Live verification against the user's real imported notes (not mock) made the
  monospace-everything problem and the fix both obvious.
- Reviewer's "critical" #1 (NSRange/UTF-16) was correctly downgraded: indent
  counts only ASCII whitespace, markup tokens are ASCII → offsets exact. Analysis
  beat reflexive "fix it".

## What was bumpy
- First visual test opened the wrong path (`obsidian/AGENTS.md`): the user's UI
  import used `into: nil` → files landed at the vault ROOT, not under `obsidian/`.
  Lesson: the UI Import has no "subfolder" field, so everything imports to root.
- UI automation/screenshots remain flaky (Stage Manager intercepts clicks; black
  frames when display sleeps). Verify via API + targeted screenshots; don't loop.

## Follow-ups
1. Incremental highlighting (perf) — full-storage restyle per keystroke; janky on
   large notes. Deferred this sprint (risky to rush; multi-line constructs).
2. Inline image rendering (NSTextAttachment) + table column alignment — deferred.
3. Consider an "import into subfolder" field in the UI Import sheet (so vaults
   don't always dump at root).
4. Vault `~/Svod/personal` is messy from import tests + the user's root import
   (AGENTS.md etc. at root, plus obs-daily/). Clean up when convenient.
