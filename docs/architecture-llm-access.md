# Architecture — LLM Access

**Date:** 2026-06-29 · **Branch:** `feat/llm-access` · **Contract:** 0.16.0 → **0.17.0**

## Contract (engine `svod`, delegated)

New, **not** vault-scoped (no `?vault=`). Persisted via `ConfigStore`; hot-applied
to `AgentRegistry`.

### `GET /api/v1/agents` → `AgentsDto`
```jsonc
{
  "agents": [
    { "agentId": "claude-desktop", "name": "Claude Desktop", "role": "WRITE",
      "vaults": ["personal","work"], "tokenRef": "file:/…/claude-desktop-token.secret",
      "prompt": null }
  ],
  "mcpPort": 7620,
  "mcpUrl": "http://127.0.0.1:7620"
}
```
- `tokenRef` is the **ref string from config**, never the resolved secret. The app
  reads the file locally to Copy the actual token.

### `POST /api/v1/agents` → 201 `AgentDto`
Body `CreateAgentRequest { agentId, name?, role, vaults:[], tokenRef, prompt? }`.
- `agentId` must match `^[a-z0-9][a-z0-9_-]*$` → else **400**.
- `role` ∈ {`READ_ONLY`,`WRITE`} (case-insensitive) → else **400**.
- `tokenRef` must be a Secrets ref (`env:`/`file:`/`keychain:`); a raw value → **422**.
- duplicate `agentId` → **409**.

### `PUT /api/v1/agents/{id}` → 200 `AgentDto`
Body `UpdateAgentRequest { name?, role?, vaults?, tokenRef?, prompt? }` (all optional;
omitted = unchanged). Unknown id → **404**. Bad role/tokenRef → 400/422.

### `DELETE /api/v1/agents/{id}` → 200 `{ "agentId": "…" }`
Unknown id → **404**. (No "last agent" guard — zero agents is valid; it just means
no LLM may connect.)

Every mutating call: `configStore.update { it.copy(agents = …) }` then
`registry.reload(configStore.config.toAgentSpecs())`.

## Engine implementation (delegated to `svod`)

- `SvodConfig.AgentSettings`: add `val prompt: String? = null` (config-only; not
  threaded into `AgentSpec`/auth).
- `mcp/Agent.kt` `AgentRegistry`: make `byToken`/`agentIds` `@Volatile var` behind a
  `reload(agents: List<AgentSpec>)` that rebuilds both maps. `authenticate` reads the
  volatile reference, so MCP picks up changes with no restart.
- `api/AgentRouting.kt` (new): interface `AgentAdmin` with `list()/create/update/delete`
  + typed exceptions `InvalidRequest`(400) / `Conflict`(409) / `NotARef`(422) /
  `UnknownAgent`(404). DTOs in `AppDtos.kt`.
- `lifecycle/AgentController.kt` (new): implements `AgentAdmin`; holds `ConfigStore` +
  `AgentRegistry`; reads `config.mcpPort` for the list response; validates id/role/ref;
  mutates config + reloads the registry.
- `api/AppApiServer.kt`: inject `agentAdmin: AgentAdmin? = null`; add the 4 routes
  mirroring the `/api/v1/vaults` block; null ⇒ `notImplemented`.
- `lifecycle/SvodNode.kt`: build `AgentController(configStore, registry)` and pass it
  as `agentAdmin = …` (registry already constructed at line ~107).
- `ApiCompatibility.CURRENT_CONTRACT_VERSION` → `0.17.0`; `AppApiServer.Config.apiVersion`
  default → `0.17.0`; `contract/openapi.yaml` paths + schemas + `version: 0.17.0`.
- Tests (`AgentAdminTest.kt`): create→201 + `registry.authenticate(token)` works with
  **no restart**; dup→409; bad id→400; raw token→422; update role/vaults reflected in
  registry; delete→authenticate null + 404 on re-delete; `list()` carries `mcpPort`.

## UI implementation (this repo)

### Networking
- `DTOs.swift`: `Agent` (`agentId,name,role,vaults,tokenRef,prompt?`),
  `AgentsInfo` (`agents:[Agent], mcpPort:Int?, mcpUrl:String?`),
  `CreateAgentRequest`, `UpdateAgentRequest`. Lenient decode.
- `SvodClient`: `agents() -> AgentsInfo`, `createAgent(_:) -> Agent`,
  `updateAgent(id:_:) -> Agent`, `deleteAgent(id:)`. Not vault-scoped.
- `LiveSvodClient`: GET/POST `/api/v1/agents`, PUT/DELETE `/api/v1/agents/{id}`
  (id path-encoded), mirroring `createVault`/`deleteVault`.
- `MockSvodClient`: in-memory list seeded with two agents (foundry + claude-desktop),
  CRUD against the static list, `mcpPort: 7620`.

### Feature
- `Features/Settings/AgentsSettingsView.swift`: a `Form` panel.
  - **Connection** section: `mcpUrl` with a Copy button (shown when present).
  - **Agents** list: name, role badge, vault chips, per-row menu (Edit / Copy token /
    Copy connection / Delete-with-confirm).
  - **Add / Edit** sheet (owned by the view via a `@State item`): name → auto-slug
    `agentId` (editable, pattern-validated), role Picker, vault multi-select (from
    `app.vault.vaults`), optional prompt `TextEditor`, and token handling:
    *generate* (default, shows the generated token once with Copy) or *reuse existing*.
    On save: write the 0600 secret file → `file:` ref → create/update.
  - Token storage helper mirrors `IndexingSettingsView.storeEmbedKey`: per-agent file
    `agent-<id>-token.secret`, 0700 dir / 0600 file, returns `file:` ref.
  - Graceful 501/404 → "needs a newer Svod engine" banner; whole panel read-only.
- `SettingsScene`: add `case llmAccess` (title "LLM Access", icon `key.horizontal`)
  between `indexing` and `appearance`; route to `AgentsSettingsView()`.

## Security notes

- Raw token is generated client-side (`UUID`-based, 256-bit), shown once, written
  0600, handed over only as a `file:` ref. Never logged, never on argv, never in
  `@State` after save.
- `GET /agents` returns only the ref, so a future non-loopback transport never leaks
  the secret; Copy works because the app is loopback-local and reads the file itself.
- Deleting an agent revokes access on its next call (registry reload); the secret file
  is also removed by the app on delete.
