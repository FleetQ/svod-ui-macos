# Svod MCP "hang" incident 2026-07-03 → mcp-remote replaced by own bridge

Agent reported "MCP server hung mid-session, never recovered" and blamed an engine `edit`-handler deadlock. **The engine never hung** — full timeline from three logs (engine.out.log is UTC+3 local; mcp-server-svod.log is UTC):

1. Claude Desktop reached the engine MCP (:7620) via `npx -y mcp-remote` (0.1.38 = LATEST, npx-cached). Worked all afternoon; last good call id=28 = commit e3fdb05, 19:57:49 local.
2. 20:10:54 the user restarted the engine (launchctl kickstart via UI). MCP sessions live in an in-memory `ConcurrentMap` in `SvodMcpServer` → all session ids died with the process (by design).
3. During the ~90s cold start mcp-remote's SSE reconnect hit `ECONNREFUSED` twice → "Maximum reconnection attempts (2) exceeded" → gave up FOREVER.
4. Every later POST (id=29 20:40, id=30 22:14, id=31 22:18 local — the "hung edits/write") → engine 404 "Session not found" (correct per streamable-HTTP spec). **mcp-remote swallows the 404: no error to the client, no re-initialize** → each call hangs to the 4-min client timeout. Only restarting Claude Desktop respawns the proxy.
5. Meanwhile direct-HTTP clients were fine (Claude Code write 22:15 OK). Vault + index intact (headIndexed caught up past manual commit 7a98870).

## Debug gotchas learned
- `Getting Tool: "<name>"` in engine.out.log = an actual tools/call dispatch; its ABSENCE during a "hang" proves the request never reached the server. `Adding Tool:` ×15 + `Adding session:` = a session init (churn is normal, ~every 2-5min; 742/day, sessions never removed = benign leak, cleared on restart).
- The engine has intermittent SLOW windows (several minutes): actor tasks queue behind sync-cycle/watcher work + Spotlight I/O storms; reads can take 3-10s. Probes with 6-8s timeouts during such a window mimic a deadlock perfectly — I chased a phantom "second deadlock" for a while. Check `/api/v1/metrics` (`queueDepth`, `write.avgMs`) and thread-dump (`kill -QUIT`, dump lands in engine.out.log) before concluding deadlock. WriteActor idle + queueDepth 0 ⇒ no wedge.
- MCP auth 401 without token is expected; a healthcheck initialize needs a real agent bearer token (tokens in ~/.claude.json mcpServers.svod / Desktop config env).
- Session-kill repro without engine restart: HTTP DELETE /mcp with `Mcp-Session-Id` → engine closes+removes the session → next POST on that id 404s.

## Fixes (svod repo commits 37d9e8c + 019e38e, 2026-07-03)
- **`dist/bridge/svod-mcp-bridge.mjs`** — 117-line zero-dep node stdio↔HTTP bridge, REPLACES mcp-remote in Claude Desktop config (`claude_desktop_config.json`, backup at `.bak-20260703`). Per-request timeout (SVOD_BRIDGE_TIMEOUT_MS, default 60s) → JSON-RPC error instead of hang; on 404 transparently re-initializes (replays client's initialize params) + retries once; skips SSE entirely (engine has enableJsonResponse=true and no server notifications, listChanged=false). Env: SVOD_MCP_URL, SVOD_AUTH. Verified: normal flow, killed-session transparent recovery (201ms), dead-server → fast structured errors, process survives.
- **SvodMcpServer.kt** — logs session init/close + unknown-session 404s (they were invisible). mcp.* tests green. Committed, NOT yet deployed (needs installDist+kickstart, do with next engine deploy).
- OPEN: `lattice` entry in Desktop config still uses mcp-remote → same wedge risk on lattice restarts. Claude Desktop must be restarted to pick up the new svod bridge.
