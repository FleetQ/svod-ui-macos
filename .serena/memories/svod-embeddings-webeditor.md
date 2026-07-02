# Svod UI — web editor + embeddings/indexing (Session 3, 2026-06-14/15)

All merged to `main` (PR #1 web-editor+sources, PR #2 embeddings, PR #3 launchd+editor-polish). Engine **v1.2.1, App API 0.8.0**.

## ⭐ Stable embedder setup = LOCAL OLLAMA bge-m3 (read this first)
**Semantic search embeds the QUERY at request time** → the embedder must be LIVE whenever you search, not just during indexing. A transient remote pod that you delete after bulk-embed → semantic search returns **0 hits** (query can't be embedded). Hard-learned: deleting the RunPod pod after the bulk embed broke semantic search.
**Resolution / current config:** provider **local-ollama**, model **bge-m3**, endpoint `http://127.0.0.1:11434`.
- Ollama is installed (`/opt/homebrew/bin/ollama`, :11434). `ollama pull bge-m3` (1024-dim). Embeds on **Metal GPU → ~9% CPU** (NOT the onnx-CPU 700%/7-core storm). Free, always-on, survives engine restarts (engine persists embedder to config).
- Ollama bge-m3 (1024-dim) is **compatible** with a TEI-bge-m3-built index (same model/pooling) — semantic search returned relevant hits immediately. Switching provider triggers a one-time local re-embed (~70 docs/s on Metal); keyword + existing semantics work throughout.
- Verify: `GET /api/v1/search?q=...&mode=semantic&vault=personal` returns hits (not 0). hybrid/keyword always work (BM25).

RunPod TEI is fine ONLY for a one-off heavy bulk embed, but queries still need a persistent embedder → for a personal KB use local Ollama for both. `tooling/runpod-embed*.mjs` remain but are not the day-to-day path.

## Editor = web (Path C), NOT native NSTextView
- `Svod/Features/Editor/WebEditorView.swift` — WKWebView hosting bundled **CodeMirror 6 + markdown-it + highlight.js + mermaid**. Modes: Edit (CM6) / Preview (rendered, default). `Svod/Resources/webeditor/{editor.html,css,bundle.js}` (5MB offline); build via `tooling/webeditor/` (`npm run build`, esbuild). Mermaid `securityLevel:"antiscript"`. CM6 `[[wikilink]]` autocomplete. Bridge: setContent/setMode/setNoteNames/setFocusMode/configure ↔ change/openLink/openExternal/ready.
- Deleted native editor: MarkdownTextView, TableRenderer, MarkdownSyntaxHighlighter, native MermaidRenderer, WikilinkAutocomplete, LinkPreviewCard. `nsColor()` → `DesignSystem/NSColorBridge.swift`.
- Gotcha: `.task(id:)` must hang off a STABLE container, not a branching `content` view (else infinite reload loop).
- **Focus mode** (PR #3): CM6 `ViewPlugin` dims every line except the caret's; toolbar ⌥⌘F toggle (disabled in Preview); `WebEditorView` passes `focusMode` → `setFocusMode`.
- **Transient "cancelled / Something went wrong" on first note open** fixed (PR #3): `EditorModel.load` does `if Task.isCancelled { return }` in catch (superseded `.task(id:)`).
- Rationale: `claudedocs/research_markdown-rendering_2026-06-14.md`.

## External Sources + import followSymlinks (contract 0.7.0)
`SourcesSettingsView` (Settings → Sources): register/sync/sync-all/remove external dirs; followSymlinks+prune; expands conflict list. ImportView "Follow symlinks" checkbox. Client: listSources/registerSource/removeSource/syncSource/syncAllSources.

## Embeddings & indexing UI (contract 0.8.0)
- Engine **non-blocking keyword-first**: BM25 immediately; semantic builds in background (throttled, resumable).
- Providers: none / local-onnx / local-ollama / remote-openai.
- `Svod/Features/Settings/IndexingSettingsView.swift` (Settings → Indexing): live progress (done/total, Pause/Resume/Re-index); provider chooser; remote = named services (OpenAI/Together/Custom·RunPod) → paste key, model/endpoint auto; **Concurrency (maxThreads)** in Advanced.
- **Key handling:** paste raw key → app writes 0600 file (`~/Library/Application Support/Svod/embed-key.secret`) → sends only a `file:` Secrets ref to engine. Raw key NEVER crosses App API (engine rejects raw with 422).
- DTOs: EmbedderInfo/EmbeddingStatus/EmbedderRequest/EmbedderTestResult; Settings.embedder; IndexStatus.keywordReady/.embedding. Client: setEmbedder/testEmbedder/reembed/pauseIndex/resumeIndex.
- Engine builds `{endpoint}/v1/embeddings` → set Endpoint WITHOUT trailing `/v1`.

## Engine autostart via launchd — INSTALLED & working (PR #3)
- `tooling/install-svod-engine-launchd.sh` installs the `dev.svod.engine` user agent (RunAtLoad + KeepAlive) → engine auto-starts at login, restarts on crash, and the app's **"Start Svod" button works** (`launchctl kickstart -k gui/$UID/dev.svod.engine`). Re-run after `./gradlew installDist`.
- The agent runs a generated wrapper `~/Library/Application Support/Svod/run-engine.sh` that:
  1. invokes **`java -cp <installDist>/lib/* dev.svod.engine.MainKt <config>` DIRECTLY** — the gradle launcher does NOT forward its config arg under launchd's minimal env, so the engine fell back to a default single-vault config and crash-looped with `MissingFieldException: 'vaultPath' is required`. (Works in an interactive shell; fails under launchd.)
  2. `rm -f ~/Svod/*/.git/index.lock` before exec — an uncleanly-killed engine leaves a stale git index lock; the next start dies with jgit `LockFailedException` (DirCache.lock → AddCommand) and KeepAlive crash-loops.
- Cold boot ~75s (onnx + Lucene + embed resume); script waits up to 130s. Logs: `~/Library/Logs/svod/engine.{out,err}.log`. Vault lock: `~/Svod/<vault>/.svod/lock`.

## Provider health row (app v0.2.3, 2026-07-02)
IndexingSettingsView shows a passive health row for the APPLIED embedder: `POST /api/v1/embedder/test` (engine embeds a real test string → catches Ollama down / model not pulled / pod gone, not just TCP). Live probe returned `{ok:true,dimension:1024,latencyMs:~134}`; dead endpoint → `{ok:false}` (200, no error text). Probes on panel open, after Apply, every ~14s (7th tick of the 2s status poll); never probes the unapplied form draft. Dead provider semantics (verified/known): keyword BM25 unaffected; semantic = 0 hits (query embeds at request time); background embedding stalls then RESUMES when provider returns — vectors are kept.

## Model + RunPod notes
- **Model for BG+EN: `BAAI/bge-m3`** (1024-dim, no prefixes, 100+ langs incl. Bulgarian). personal vault ≈ 62.6k chunks.
- **AVOID RunPod serverless workers** (`worker-infinity-embedding`, `worker-v1-vllm`): wedge under load (jobs stuck `inProgress`, idle workers don't pick up); vLLM template defaults to wrong model (Qwen3-8B), key auto `sk-<pod-id>`.
- RunPod **TEI pod** (one-off bulk only): image `ghcr.io/huggingface/text-embeddings-inference:1.8`, dockerStartCmd `--model-id BAAI/bge-m3 --auto-truncate --max-client-batch-size 256`, port 80, volumeInGb 0. OpenAI `/v1/embeddings`, no auth. ~350 docs/s @ maxThreads 3 → 62.6k in ~4 min ~$0.03. REST `https://rest.runpod.io/v1/pods`; key `~/.config/svod/runpod-api.key` (0600, never committed). GraphQL `api.runpod.io/graphql?api_key=` for gpuTypes.
- RunPod gotchas: pod DNS can break (resolv.conf Docker `127.0.0.11` fails, egress fine → `printf "nameserver 1.1.1.1">/etc/resolv.conf` or another region; EU-RO-1 had no DNS). Basic SSH `ssh <pod>-<n>@ssh.runpod.io` needs `-tt` + commands via stdin; old RSA keys need `-o PubkeyAcceptedAlgorithms=+ssh-rsa`. bge-m3 tiny → cheapest 16GB (RTX A4000 $0.25).

## Run the engine from source (dev)
`cd ~/htdocs/svod/engine && JAVA_HOME=$(/usr/libexec/java_home -v20) ./gradlew installDist` then `build/install/svod-engine/bin/svod-engine ~/htdocs/svod/dist/config.local.multivault.json` (App API :7619, vaults personal/work). gradle blocked by context-mode Bash hook → use ctx_execute. Vault-lock gotcha: killed JVM holds `~/Svod/personal/.svod/lock` — kill stray `dev.svod.engine.MainKt`. onnx-CPU embedding pegs ~7 cores (reason for remote/throttle/non-blocking + the local-Ollama-GPU choice).

## Pending engine-side (prompt handed to engine team, not yet done)
- **Embedding should RESUME across restarts** — the engine currently re-runs a full embedding pass on every restart even when nothing changed. Desired: on boot, if embedder identity (provider/model/dim) + indexed git HEAD unchanged → no-op; else embed only the delta (new/changed/missing-vector docs). Dimension/model change still = full re-embed.
- **Engine should self-heal a stale `<vault>/.git/index.lock` on boot** (after acquiring its VaultLock) instead of crash-looping. (Currently worked around in the launchd wrapper.)
