# recall borrowed-ideas sprint (2026-07-15) — SHIPPED

Mined ideas from Viget's "recall" persistent-memory design for Claude Code
(viget.com/articles/giving-claude-code-a-persistent-memory, repo maxdmyers/recall)
via `/sc:research`. Eval: recall is the LIGHTWEIGHT version of what Svod already is
(git-markdown vault + SessionStart index injection). We DON'T borrow its storage
(Svod engine > recall's flat markdown). We borrowed the **write-side automation**
we lacked: automatic capture, off-session distill, proposals inbox. Notably recall's
#1 idea (Stop-hook capture → messy/) IS the deferred capture-writer follow-up from
`mem:svod-claude-mem-borrowed-ideas`.

Operator chose: all phases · scope svod-ui-macos only · implement as **engine features**
→ deploy :7619 → app release. Same playbook as claude-mem sprint: engine (Kotlin)
delegated to `svod` via Harbormaster; UI (SwiftUI) here.

## Shipped
- **Engine: DEPLOYED LIVE.** svod-engine **v1.11.0 / contract 0.22.0** on :7619
  (release commit `2fce9cd`, ff-merged to main `be83eb3..2fce9cd`, tag `v1.11.0`
  pushed → CI). New `memory/RecallMemory.kt` + `api/MemoryRouting.kt`; 7 App API
  routes; `LuceneIndex.buildFilter` unconditionally excludes `messy/sessions/`
  (no includeAll/includeMessy/prefix escape — raw transcripts stay out of recall).
  Tests 218: **216 pass / 0 fail / 2 skip** (new MemoryApiTest + RecallGuardsTest).
  Live smoke: /ready 200, capture 200 + dedup, dashboard 200, includeAll search 0
  hits from messy/sessions/. **Enum wire convention = lowercase** (kind/scope/status).
- **UI (svod-ui-macos): app v0.2.10 (build 12) RELEASED** — main `ec16a10`
  (feature `86bb0d7` + release `ec16a10`). Signed (Developer ID PRICEX LTD EOOD) +
  notarized **Accepted** + stapled, appcast pushed, DMG **6,137,770 B**, edSignature
  length matches DMG+GH asset (Sparkle-valid). Released via `Scripts/release.sh 0.2.10 12`
  with `PUBLISH=1 NOTARY_PROFILE=lattice-notary`. This time PUSHED main BEFORE the
  release so `gh release create` tags the right commit (fixes the tag-drift from 0.2.9).

## What each idea became
1. **Capture (free, no LLM):** `.claude/settings.json` `Stop` hook →
   `.claude/hooks/capture-session.sh` (jq compacts transcript, curl POSTs to
   `POST /api/v1/memory/capture`). Best-effort, localhost-only, always exits 0.
   Engine stores under `messy/sessions/<endedAt>-<slug>-<sid8>.md`, idempotent on
   sessionId (`deduped:true`).
2. **Distill (cheap, off-session):** `Scripts/recall-distill.sh` = thin
   `claude -p --model claude-haiku-4-5` wrapper over `.claude/hooks/recall-distill-prompt.md`
   (GET undistilled → compress to messy/recall drafts → mark-distilled → append proposals).
   `Scripts/dev.svod.recall-distill.plist` (nightly 03:30). **STAGED opt-in — NOT loaded.**
   Deliberately not auto-scheduled: it's an autonomous recurring PAID job writing to the
   vault (Action Safety). Enable = cp plist to ~/Library/LaunchAgents + launchctl bootstrap.
3. **Proposals inbox (surface):** engine `GET/POST /api/v1/memory/proposals[/{id}]`;
   UI Settings→**Memory** panel lists open proposals with Accept/Reject. Accept only
   FLAGS (suggestions-over-automation) — never auto-creates a skill/tool.
4. **Dashboard:** `GET /api/v1/memory/dashboard` → counts + compressionRatio; shown in panel.
- **project→global promotion:** DEFERRED (scope = this project); `scope` field exists on
  proposals for a future all-htdocs rollout.

## UI shape (matches conventions)
- DTOs appended to `DTOs.swift`: `MemoryDashboard/MemorySession/MemoryProposal`
  (+ `MemoryProposalAction` request), tolerant `init(from:)` with `try?` fallbacks,
  enums normalized lowercase on decode (robust to engine casing). Sessions/proposals
  are **bare arrays** on the wire; dashboard has optional `lastDistillAt`.
- `SvodClient` (frozen contract, extended like agents/sources before it): +4 methods
  `memoryDashboard/memorySessions/memoryProposals/resolveProposal` on Live + Mock.
- `Features/Settings/MemorySettingsView.swift` — self-contained `@State` panel (AgentsSettingsView
  pattern), `app.client`, degrades on `.isNotImplemented` (<0.22.0). Registered in
  `SettingsScene` (`.memory`, icon "brain"). NO frozen AppModel/RootView/centerMode churn —
  Settings panel was the lowest-blast-radius surface.
- Build green, zero source warnings (the lone AppIntents metadata line is a benign toolchain notice).

## Key lessons
- Recall's value for us wasn't storage (we're heavier) but the automation we lacked;
  ground "borrow this tool" evals in what's already built (idea #1 = our own deferred TODO).
- Harbormaster engine deploy needs the EXPLICIT-override clause quoting operator authorization
  verbatim (the svod project's "do NOT commit" footer otherwise stops before push/deploy) —
  same as `mem:svod-claude-mem-borrowed-ideas`. Worked first try this time; job ran ~25 min.
- Release tag drift fix: `git push origin main` BEFORE `release.sh PUBLISH=1` so
  `gh release create` tags the pushed HEAD, not the older remote HEAD.
- Backgrounding `release.sh` with an inner `&` AND `run_in_background:true` double-detaches →
  the tool's "exit 0" is the launcher, not release.sh. Use one or the other; poll the real pid.
- Distill-as-engine-feature would mean putting generative LLM + API key into the Kotlin engine;
  instead the engine owns the DATA plane and an external `claude -p` does the compute (faithful
  to recall). Documented in `claudedocs/design_recall-memory-feature_2026-07-15.md`.

Related: `mem:svod-claude-mem-borrowed-ideas`, `mem:svod-ui-architecture`,
`mem:svod-engine-deploy-launchd`, `mem:svod-ui-release-signing`.
