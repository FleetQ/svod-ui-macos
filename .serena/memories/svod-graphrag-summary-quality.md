# Svod — making graph community summaries usable (v1.15.1, 2026-08-17)

Follow-up to `mem:svod-graphrag-levels-1-2`. The Ниво 2 feature shipped in v1.15.0 and the first real
build on the personal vault produced **12 usable summaries out of 21**. Getting to 21/21 took three
fixes and, more importantly, a better metric.

## The three failure modes, in the order they became visible

1. **A bolded label was never parsed** (2/21). `qwen2.5:7b` answered `**TITLE: …**`; the matcher
   anchored on `^\s*TITLE:` and missed it, so the label text leaked into the summary body and the
   title silently fell back to a folder name. Labels now tolerate leading markdown/bullet/quote
   characters and strip emphasis from the captured value.
2. **The model continued the documents instead of summarising** (6/21). The instruction sat BEFORE
   ~12,000 characters of source text. A 7B model reads a leading instruction as more document and
   keeps writing. Fix: fence the excerpts with explicit delimiters, put the instruction AFTER them,
   and move the role instruction out of the prompt into Ollama's `system` field.
3. **The model answered in Chinese** (8/21). This was **hidden behind 1 and 2** — a model busy copying
   documents stays in the document's language, so the drift only appeared once it was generating for
   real. "Write in the language predominant in the notes" is a judgement a 7B model does not make
   reliably. Fix: `dominantLanguage()` counts Cyrillic vs Latin **in code** and emits one unambiguous
   instruction.

## The lesson that generalises

**A metric that cannot see a failure mode will report success through it.** After fixes 1+2 the
scoring script reported "21/21 usable" — it only checked for leaked labels and echoed source. Eight of
those were in Chinese and unreadable for the operator. The real number was 13/21, barely better than
the 12/21 it started at. Always ask what the metric *cannot* see before trusting an improvement.

Corollary: when a fix reveals a new failure, check whether it **created** it or **unmasked** it. Here
it was unmasking, which changes the diagnosis completely.

## Implementation notes

- `buildPrompt` returns `BuiltPrompt(prompt, language)` so the footer instruction and the `system`
  clause carry the SAME decision. Deriving the language from the assembled prompt instead classified
  every vault as Bulgarian, because the prompt contains the engine's own Cyrillic instruction text.
  Caught by the English-side test, not by review.
- `SummaryLlm.summarise(prompt, system)` — the system parameter exists precisely so the instruction
  cannot be mistaken for input.

## Measured on the real vault (3,096 notes, 21 eligible communities)

| | usable | build time |
|---|---|---|
| v1.15.0 | 12 / 21 | 17 min |
| after fixes 1+2 | 13 / 21 (8 in Chinese) | 3.5 min |
| **v1.15.1** | **21 / 21** | **7.2 min** |

A model that answers in two lines instead of reciting documents is also far cheaper — the build time
more than halved as a side effect of the quality fix.

## Operational

- An existing sidecar does NOT pick this up automatically: `POST /api/v1/graph/rebuild?vault=<id>`.
- Contract unchanged (0.24.0), no reindex, no graph schema change.
- The live config (`dist/config.local.multivault.json`) has `graph.enabled: true` with
  `summaryProvider: "ollama"` and `qwen2.5:7b-instruct`; the block is top-level so it covers
  personal/work/lukanet. `rebuildOnStartup: false` — builds are explicit.
- **`work` and `lukanet` had not been built** as of this writing; only `personal`.

Suite: 313 tests, 311 passed, 2 skipped.
