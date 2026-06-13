# Architecture — Markdown rendering fixes

Files (Teammate-1 Editor domain): `Svod/Features/Editor/MarkdownSyntaxHighlighter.swift`
(styling) and `Svod/Features/Editor/MarkdownTextView.swift` (NSTextView + link clicks).
DesignSystem tokens only; no new colors unless a token exists.

## Changes

### MarkdownSyntaxHighlighter.swift
- **Fonts:** `baseFont` → `NSFont.preferredFont(forTextStyle: .body)` (proportional).
  Keep a separate `monoFont` (monospaced) for code/tables. `styleHeadings` uses
  `NSFont.systemFont(ofSize:weight:)` (proportional), not mono.
- **styleMarkdownLinks (new):** regex `(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)`. Color the
  `[text]`, dim `[` `]` `(url)`, add `.link = <url>` over the text range. (Negative
  lookbehind `(?<!!)` so image syntax isn't matched.)
- **styleImages (new):** regex `!\[([^\]\n]*)\]\(([^)\n]+)\)`. Alt → secondary;
  dim `![ ]( )` + url. No attachment.
- **Task lists (in styleLists):** detect `- [ ] ` / `- [x] ` (and `*`/`+`). Color the
  `[ ]`/`[x]` token (done = ThemeColor.sync/green). For `[x]`, dim + strikethrough
  the remainder of the line.
- **styleStrikethrough (new):** regex `~~([^~\n]+)~~` → `.strikethroughStyle` on
  content; dim the `~~` markers.
- Order in `highlight()`: headings → fenced code → blockquotes → tables → lists →
  images → links → inline code → emphasis → strikethrough → wikilinks. (Images
  before links; code/wikilinks keep their slots.)

### MarkdownTextView.swift
- Link click handler: `svodwiki://` → existing wiki nav; `http`/`https` →
  `NSWorkspace.shared.open`. (Read current handler; extend, don't replace.)
- Ensure the NSTextView's default/typing font is the proportional base (not mono)
  so newly typed text matches.

## Data flow
Unchanged: EditorModel.draft → MarkdownTextView binding → highlighter restyles
NSTextStorage. Clickable links flow through the existing `.link` attribute +
coordinator `clickedOnLink`.

## Risks
- Proportional base must not break the `~70ch` measure / cursor — NSTextView
  handles proportional natively; verify visually.
- Regex over the whole doc each keystroke (existing perf characteristic; unchanged).
