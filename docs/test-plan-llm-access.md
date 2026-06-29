# Test Plan — LLM Access

**Date:** 2026-06-29 · **Branch:** `feat/llm-access`

## Engine (delegated, `AgentAdminTest.kt` + live :7619)

| # | Case | Expect |
|---|------|--------|
| E1 | `POST /agents` valid | 201 `AgentDto`; persisted in config; `registry.authenticate(token)` resolves **without restart** |
| E2 | duplicate `agentId` | 409 |
| E3 | bad `agentId` (`Foo!`) | 400 |
| E4 | raw token (not a ref) | 422 |
| E5 | bad `role` | 400 |
| E6 | `PUT /agents/{id}` role/vaults | 200; registry reflects new role + vault grant |
| E7 | `PUT` unknown id | 404 |
| E8 | `DELETE /agents/{id}` | 200; `authenticate(token)` → null next call; config no longer lists it |
| E9 | `DELETE` unknown id | 404 |
| E10 | `GET /agents` | lists agents + `mcpPort` + `mcpUrl`; `tokenRef` is the ref, never the resolved secret |
| E11 | survives restart | added agent still present after engine reboot (ConfigStore persisted) |

## UI (build + manual)

| # | Case | Expect |
|---|------|--------|
| U1 | `xcodebuild` Debug | green, zero new warnings |
| U2 | Mock preview | panel lists seeded agents, shows MCP URL |
| U3 | Add agent | name auto-slugs id; pattern rejects bad id inline; token generated + shown once |
| U4 | Copy token / connection | pasteboard gets token / `URL + token` |
| U5 | Edit role + vaults | reflected in list after save |
| U6 | Delete | confirm dialog; row removed; secret file deleted |
| U7 | Old engine (Mock `.notImplemented`) | "needs a newer Svod engine" banner, panel read-only |
| U8 | Live :7619 | add LLM in UI → new entry in `config.local.multivault.json` → MCP auth works with that token, **no restart** |

## Acceptance

- All E# pass in the engine suite (`./gradlew test --rerun-tasks`).
- U1–U7 pass locally; U8 verified live once the engine delegation is deployed to :7619.
- No raw secret ever sent over the App API (engine 422 on raw; app sends only `file:` ref).
