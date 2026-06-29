# Svod UI — LLM Access (manage MCP agents) — session 2026-06-29

Adds a `Settings → LLM Access` panel to manage the MCP **agents** the engine
authorizes (which LLMs may reach the vaults over MCP). Before this, agents existed
only in the engine config JSON (`agents[]`) and required a hand-edit + restart.
Builds on `mem:svod-ui-create-vault` / `mem:svod-ui-delete-vault` (same CRUD pattern).

## What an "agent" is
One authorized MCP client (LLM): `{ token (Secrets ref), agentId (slug), role
(READ_ONLY|WRITE), name?, email?, vaults[], prompt? }` in the engine config. LLMs
connect via the **MCP endpoint** `mcpPort` (live: `127.0.0.1:7620`), NOT the App API
(:7619). `prompt` is optional, config-only convenience metadata — the engine does NOT
enforce it (MCP carries no system prompt).

## Engine (~/htdocs/svod, FleetQ/svod-engine, commit `3c4adb6` on main + PUSHED, contract **0.17.0**, DEPLOYED live to :7619)
- NEW `GET/POST/PUT/DELETE /api/v1/agents` (NOT vault-scoped, no `?vault=`).
  - `GET` → `AgentsDto { agents:[AgentDto{agentId,name,role,vaults,tokenRef,prompt?}], mcpPort, mcpUrl }`. `tokenRef` is the config ref string, NEVER the resolved secret.
  - `POST` 201 AgentDto; `CreateAgentRequest{agentId,name?,role,vaults[],tokenRef,prompt?}`. 400 bad id (`^[a-z0-9][a-z0-9_-]*$`)/bad role; **422 raw token** (must be a Secrets ref env:/file:/keychain:); 409 dup id.
  - `PUT /{id}` 200 AgentDto; `UpdateAgentRequest` partial (omitted = unchanged); 404 unknown.
  - `DELETE /{id}` 200 `{agentId}`; 404 unknown. No last-agent guard — zero agents is allowed.
- **Hot-reload (the core lift):** `AgentRegistry` `byToken`/`agentIds` are now `@Volatile var` + `reload(specs)` (build-then-swap); `authenticate` reads the volatile field. `AgentController` mutates config via `ConfigStore.update{}` then `registry.reload(config.toAgentSpecs())` → a new agent authenticates on its NEXT MCP call, **no restart**.
- New files `api/AgentRouting.kt` (AgentAdmin iface + typed errors), `lifecycle/AgentController.kt`. `SvodConfig.AgentSettings.prompt` added. AppApiServer takes `agentAdmin: AgentAdmin? = null` (null ⇒ 501), mirrors the vaults route block. `SvodNode` builds `AgentController(configStore, registry, config.host)`.
- Tests: `AgentAdminTest.kt` (hot-reload-without-rebuild, 409/400/422/404, update reflected, zero-agents-ok) + `AppApiContractTest.kt`. Full suite green (`./gradlew test --rerun-tasks`, 1m18s, BUILD SUCCESSFUL).
- LIVE VERIFIED on :7619: apiVersion 0.17.0; POST→201, dup→409, raw→422, bad-id→400, PUT→200+persisted to config file, DELETE→200, re-DELETE→404; cleaned up (back to 4 real agents foundry/claude-desktop/claude-code/lm-studio). MCP auth probe was INCONCLUSIVE (hit wrong MCP path → 404 for any token); hot-reload relied on the passing unit test, not a live MCP handshake.

## UI (svod-ui-macos, commit `263f5c1` on main + PUSHED, build GREEN)
- DTOs `Agent`, `AgentsInfo{agents,mcpPort?,mcpUrl?}`, `CreateAgentRequest`, `UpdateAgentRequest` (lenient decode). `SvodClient.agents()/createAgent/updateAgent/deleteAgent` (Live: GET/POST `/api/v1/agents`, PUT/DELETE `/{id}` path-encoded; Mock: in-memory seeded list).
- `Features/Settings/AgentsSettingsView.swift`: lists agents (name, role pill, vault chips), Add/Edit sheet (name→auto-slug id, role Picker, vault multi-select from `app.vault.vaults`, optional prompt TextEditor), Copy token / Copy connection / Revoke-with-confirm. New SettingsScene section `.llmAccess` ("LLM Access", icon `key.horizontal`) between Indexing and Appearance. Graceful 501/404 → "needs a newer Svod engine".
- **Token security (same model as embedder key + GitHub token):** token is generated client-side (256-bit, `SecRandomCopyBytes` → base64url), written to `~/Library/Application Support/Svod/agent-<id>-token.secret` (0600), handed to the engine only as a `file:` ref. Raw token NEVER crosses the App API (engine 422 on raw). Copy reads the local file directly. Delete removes the secret file (guarded to Application Support/Svod/agent-*).
- Swift synthesized Codable omits nil optionals (`encodeIfPresent`) → `UpdateAgentRequest` with nil fields sends only the set fields → "omitted = unchanged" is safe (same as CreateVaultRequest).

## Process notes
- Engine delegated via harbormaster `delegate_task` (async, inbox `svod-llm-access`, job `d_31e5b9d69def`, sonnet, max_turns 80). **THIRD ~600s-wall false-failure** (`code=timeout: claude -p exceeded 600s`): status `failed` but ALL code was written (uncommitted — process died before auto_commit). Recovery (matches `mem:svod-ui-delete-vault`): read the working tree → review the new files → `./gradlew test --rerun-tasks` via `ctx_execute` (green) → commit the relevant files only (excluded the agent's `claudedocs/` + `retro/` scratch) → installDist → restart :7619 → live-verify via ctx_execute JS fetch. ALWAYS inspect the tree before redoing.
- Deploy to :7619 = `cd engine && JAVA_HOME=$(/usr/libexec/java_home -v20) ./gradlew installDist` → SIGTERM the running `java … MainKt … config.local.multivault.json` (was PID 10960) → `rm -f ~/Svod/*/.svod/lock` → relaunch detached `nohup java -cp 'build/install/svod-engine/lib/*' dev.svod.engine.MainKt <config> &`. Cold boot ~ a few s here (warm caches); poll `/ready`. gradle+curl blocked by context-mode Bash hook → use `ctx_execute`.
