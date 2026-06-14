# Design: pluggable embeddings + non-blocking indexing

**Date:** 2026-06-14
**Status:** approved direction (decisions below), engine-first
**Problem:** a fresh start re-embeds the whole vault (2727 notes) on CPU before
opening the App API port — pegs ~7 cores / 8 GB RAM for 10+ min and blocks
connection. Want (a) startup that doesn't hog the machine and (b) user choice of
embedding backend (local vs remote).

## Decisions
- **Non-blocking startup.** Engine opens the port immediately; BM25 keyword
  search works at once from Lucene; semantic embeddings build in the background,
  throttled, resumable, with progress. (Biggest win; backend-independent.)
- **Throttled local embedding.** Cap worker threads + low priority so it never
  saturates the machine.
- **Pluggable embedder provider** (user-selectable):
  - `local-onnx` — current, but throttled. Offline/private default + fallback.
  - `local-ollama` — Ollama `/api/embeddings` (e.g. `nomic-embed-text`); uses
    Metal GPU on Mac → fast, low CPU thrash, still private.
  - `remote-openai` — OpenAI-compatible `POST /v1/embeddings` (covers RunPod
    TEI/Infinity, OpenAI, Together, …). One integration, many backends.
- **Secrets, never raw keys.** Remote API keys are passed as Secrets references
  (`env:` / `file:` / `keychain:`) — same mechanism as git backup. The App API /
  UI never stores or transmits a raw key.
- **Privacy:** remote = note content leaves the machine (fine for a user's own
  RunPod pod; a consideration for public APIs). `local-ollama` is the
  "fast-but-private" sweet spot. Surface this in the picker.

## Consequences
- Switching provider/model changes the vector dimension → **full re-embed**.
  With non-blocking indexing this is a background job with progress, not a freeze.
- Embedder config is **engine-global** (one index space per vault, consistent
  model). Lives in the engine config; switching triggers a re-embed job.

## Contract additions the UI needs (engine → App API)
1. `GET /api/v1/settings` already returns `apiVersion`; add the active embedder:
   `embedder: { provider, model, endpoint?, dimension }`.
2. Index/embedding status for the progress UI (extend existing `indexStatus`):
   `GET /api/v1/index/status` →
   `{ keywordReady: bool, embedding: { state: idle|running|paused|error,
      done: int, total: int, provider, model, error? } }`
3. Live progress event over the existing WS: `index.progress`
   `{ vault, done, total, state }` (calm, throttled emit).
4. Set embedder + trigger re-embed. Prefer a runtime endpoint so the UI can
   change it without hand-editing config:
   `PUT /api/v1/embedder { provider, model, endpoint?, apiKeyRef?, threads? }`
   → validates, persists to engine config, starts a background re-embed.
   `POST /api/v1/index/reembed` (force) / `POST /api/v1/index/pause|resume`.
   501 on older engines → UI feature-detects via `apiVersion`.
5. `POST /api/v1/embedder/test { provider, model, endpoint?, apiKeyRef? }` →
   embeds a tiny probe string, returns `{ ok, dimension, latencyMs, error? }`
   so the UI "Test" button validates config before committing to a re-embed.

## Engine config schema (file)
```jsonc
"embedder": {
  "provider": "local-onnx" | "local-ollama" | "remote-openai",
  "onnxModelId": "multilingual-e5-small",      // provider=local-onnx
  "endpoint": "http://127.0.0.1:11434",         // ollama base / openai base URL
  "model": "nomic-embed-text",                   // ollama/remote model id
  "apiKeyRef": "keychain:svod-embed-openai",    // remote only; Secrets ref
  "maxThreads": 2,                                // throttle (local)
  "batchSize": 32
},
"indexing": { "blockStartup": false, "backgroundThrottleMs": 0 }
```

## UI plan (this repo)
- Settings → **Indexing & Embeddings**:
  - provider picker (onnx / Ollama / Remote) with a one-line privacy/speed note each;
  - model + endpoint fields (shown per provider); API-key field for remote stored
    as a Secrets ref (keychain default), with a **Test** button (calls /embedder/test);
  - throttle hint; **Re-index now** button.
- Progress: a calm indicator (status pill / settings row) driven by
  `index/status` + `index.progress` WS — "Semantic index 1240/2727". Keyword
  search usable throughout.
- Feature-detect on `apiVersion`; degrade to "needs newer engine" if absent.

## Rollout
1. Engine: non-blocking startup + throttled background indexing (no new providers).
   — fixes the acute pain immediately even on local-onnx.
2. Engine: provider abstraction (ollama, remote-openai) + config + status/test endpoints.
3. UI: settings + progress, feature-detected.
