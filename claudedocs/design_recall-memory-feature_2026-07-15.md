# Design: Svod "recall" memory features (engine + app UI + capture hook)

**Source of ideas:** research_recall-persistent-memory_2026-07-15.md (Viget "recall").
**Decisions:** all phases · scope = svod-ui-macos only · implement as **Svod engine features** → deploy :7619 → app release build 12.
**Builds on shipped v1.10.0 scaffolding:** `messy/` quarantine, `includeMessyInRecall` config, `<private>` exclusion. This adds the *write-side automation* that was deferred.

## Architecture (faithful to recall's 4-step loop)

```
Capture (Stop hook, no LLM) ──POST──▶ engine /memory/capture ──▶ messy/sessions/<ts>.md
                                                                      │
Distill (nightly scheduled agent, cheap model) ◀──GET undistilled────┘
   │  strips tool calls, ~compresses, writes durable notes via remember()/write
   └──POST /memory/sessions/mark-distilled + /memory/proposals (recurring patterns)
Retrieve  = existing SessionStart hook (MEMORY.md + Serena) — unchanged
Surface   = /memory/proposals inbox, human accept/reject in app UI (suggestions-over-automation)
```

**Why distill is a scheduled agent, not Kotlin LLM-calling:** faithful to recall (external headless `claude -p`); keeps generative inference + Anthropic key OUT of the engine (which only does bge-m3 embeddings today). Engine owns the **data plane**; the scheduled agent owns the **compute**. Capture/sessions/proposals/dashboard/promotion ARE the engine features.

---

## Engine (Kotlin) — App API additions · contract 0.21.0 → 0.22.0

All under existing App API server (loopback :7619). New note area: `messy/sessions/` (already MUST_NOT in recall filter) + `inbox/proposals` store.

### Endpoints
1. **`POST /api/v1/memory/capture`**
   Body: `{sessionId: String, project: String?, transcript: String, startedAt: Long(ms), endedAt: Long(ms), toolCallCount: Int?}`
   → writes `messy/sessions/<endedAt>-<slug(project)>-<sessionId[0..7]>.md` with frontmatter `{type: session, project, sessionId, startedAt, endedAt, distilled: false, bytes}`.
   Idempotent on `sessionId` (return existing path if already captured). Returns `{path, revision, deduped: Bool}`.

2. **`GET /api/v1/memory/sessions?distilled=<bool>&limit=<int>`**
   → `[{path, project, sessionId, startedAt, endedAt, bytes, distilled}]`, newest first.

3. **`POST /api/v1/memory/sessions/mark-distilled`**
   Body: `{paths: [String], noteRefs: [String]}` → sets `distilled: true` frontmatter + records the durable-note refs for dashboard compression math. Returns `{updated: Int}`.

4. **`GET /api/v1/memory/proposals?status=open|accepted|rejected`**
   → `[{id, kind: "skill"|"tool", title, scope: "project"|"global", confidence: Double, rationale, sourceSessions: [String], createdAt, status}]`. Backed by `inbox/proposals` note (structured) or a small store.

5. **`POST /api/v1/memory/proposals`** (distiller appends)
   Body: proposal without `id/status/createdAt` → engine assigns. Returns `{id}`. Dedup by (kind,title,scope).

6. **`POST /api/v1/memory/proposals/{id}`**
   Body: `{action: "accept"|"reject", note?}` → status transition only. **Accept does NOT auto-create** a skill/tool (suggestions-over-automation); it flags for the operator/foundry. Returns updated proposal.

7. **`GET /api/v1/memory/dashboard`**
   → `{sessionsCaptured, sessionsDistilled, notesWritten, capturedBytes, distilledBytes, compressionRatio, lastDistillAt: Long?, openProposals}`.

### Contract sync (per proven process)
Bump version in: `openapi.yaml`, `AppApiServer` version constant, `ApiCompatibility`, gradle `version` + `SvodNode.currentAppVersion` (engine app version → next patch/minor, e.g. **v1.11.0**). Add DTOs + routes + tests (capture idempotency, mark-distilled, proposal lifecycle, dashboard math, and a guard test that `messy/sessions/` never leaks into recall/search).

### Deploy
`JAVA_HOME=$(/usr/libexec/java_home -v 20) ./gradlew installDist` → `rm -f ~/Svod/*/.svod/lock` → `launchctl kickstart -k gui/501/dev.svod.engine` → poll `http://127.0.0.1:7619/ready` via JS fetch (~40-60s cold). Then tag `vX` push → CI release. **Gate:** /ready 200 AND the 7 endpoints respond (capture round-trips, dashboard returns).

---

## App (SwiftUI, svod-ui-macos) — Memory surface

### Networking (frozen-layer additions, additive only)
- DTOs in `Networking/`: `MemoryDashboard`, `MemorySession`, `MemoryProposal` (+ `ProposalKind`, `ProposalScope`, `ProposalStatus` enums; UPPERCASE-on-wire handling like search `mode`).
- `SvodClient` protocol: `memoryDashboard()`, `memorySessions(distilled: Bool?)`, `memoryProposals(status: ProposalStatus?)`, `resolveProposal(id:action:)`.
- `LiveSvodClient`: URLSession calls to the 4 read/act endpoints. `MockSvodClient`: seed 1 dashboard, 3 sessions, 2 proposals for previews/offline.

### Feature
- `Features/Memory/MemoryModel.swift` — `@MainActor ObservableObject`: loads dashboard+sessions+proposals, `accept/reject(proposal:)` with optimistic update + reload, offline/loading/error via existing StateViews.
- `Features/Memory/MemoryView.swift` — three sections using DesignSystem tokens only:
  - **Dashboard card**: captured/distilled counts, compression ratio, last distill, open-proposals badge.
  - **Proposals inbox**: list of MemoryProposal rows (title, scope pill, confidence) with Accept/Reject (ListRow + StatusPill + SvodButtonStyle).
  - **Recent sessions**: compact list (project, time, bytes, distilled StatusPill).
- Surface it via `AppModel` + `FeatureSlots` as a **new centerMode `.memory`** (cleanest UX) OR a Settings → Memory panel if enum churn is undesirable. Default: centerMode `.memory` with a ⌘4 command + sidebar entry; keep the frozen enum edit minimal and localized.
- Empty states are first-class (feature ships useful even before first distill).

### Build/verify
`xcodebuild -project Svod.xcodeproj -scheme Svod -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dd build` → green, zero source warnings. DTOs validated against live engine once deployed.

---

## Capture hook (project-scoped)
`.claude/settings.json` in svod-ui-macos: `Stop` hook → shell that reads Claude Code's transcript (hook provides transcript path on stdin JSON), assembles `{sessionId, project:"svod-ui-macos", transcript, startedAt, endedAt}` with `jq`, and POSTs to `http://127.0.0.1:7619/api/v1/memory/capture`. **No LLM in the hook** (recall's "capture is free"). Non-blocking, best-effort (failure must never break the session).

## Nightly distill (scheduled agent)
`schedule`/CronCreate cloud agent, nightly: GET `?distilled=false` → for each session, read transcript, strip tool calls, compress to a durable note (cheap model — Haiku 4.5), write via `mcp__svod__remember`/`write`, POST `mark-distilled`, and POST `proposals` for recurring cross-session patterns (`scope: project` default). Cost target ≈ recall's ~$0.85/night.

## project→global promotion
Scope = svod-ui-macos only for now → promotion rule is **deferred/minimal**; the `scope` field exists on proposals so a future all-htdocs rollout can promote patterns seen in 2+ projects to Serena `global/`. Flagged, not built.

---

## Release gate (build 12)
Cut **v0.2.10 (build 12)** ONLY when: engine vX.Y deployed + /ready 200 + endpoints live, AND app build green with the Memory UI. Then Scripts/release.sh (sign+notarize+staple+appcast), tag v0.2.10, GH release, verify Sparkle edSignature + spctl. Save learnings to Serena.
