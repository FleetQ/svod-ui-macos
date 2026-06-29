# Design — LLM Access (manage MCP agents from the app)

**Date:** 2026-06-29 · **Branch:** `feat/llm-access` · **Status:** Think

## Problem

The Svod engine decides *which LLMs may reach the knowledge base* through its MCP
endpoint (`mcpPort`, currently `127.0.0.1:7620`). Each authorized client is an
entry in the config's `agents[]` array — a bearer **token** (a Secrets ref), an
`agentId`, a `role` (`READ_ONLY`/`WRITE`), and the `vaults[]` it may touch. Today
those entries exist **only in `config.local.multivault.json`**. To add, edit, or
revoke an LLM's access you hand-edit JSON, create a `*.secret` token file, and
**restart the engine** (the `AgentRegistry` is built once at boot and is immutable).
There is no UI surface at all.

## Forcing questions

- **Who needs this / what do they do today?** The KB owner running local + remote
  LLMs (Claude Desktop, Claude Code, LM Studio, Svod Foundry) against Svod over
  MCP. Today: edit JSON by hand, `chmod 600` a token file, restart the engine,
  then paste the token into the LLM client's MCP config.
- **Narrowest MVP?** A `Settings → LLM Access` panel that **lists** configured
  agents and lets you **add / edit / revoke** one, with **Copy** for the token and
  the MCP URL so it pastes straight into the client. Applied **without an engine
  restart**.
- **What makes someone say "whoa"?** *Add LLM* generates a fresh token, writes the
  0600 secret file, and the new agent can authenticate **immediately** (hot
  reload). One "Copy connection" gives `URL + token` ready to paste.
- **How does it compound?** Every new LLM tool becomes a 20-second UI task instead
  of config-file surgery; token rotation and per-vault scoping become routine.

## Decisions

1. **Token never crosses the App API as a raw value** — same model as the embedder
   key and the GitHub token. The app generates a random token, writes it to
   `~/Library/Application Support/Svod/agent-<id>-token.secret` (chmod 0600), and
   sends the engine only a `file:` Secrets ref. The engine rejects a raw token with
   422. Copy reads the local secret file directly (loopback app, same machine).
2. **Hot apply, no restart.** The engine makes `AgentRegistry` reloadable and swaps
   it after every config mutation, so a freshly added agent authenticates on its
   next MCP call. This is the core engine lift.
3. **Optional per-agent `prompt`** — a convenience string stored in config and
   surfaced for copy (so you can paste a tailored system prompt into the client).
   The engine **does not enforce** it; MCP does not carry a system prompt. Purely
   metadata.
4. **Graceful degradation.** Older engine without the endpoints → the panel shows
   "needs a newer Svod engine" (501/404), same pattern as sync/backup and vaults.
5. **Engine work is delegated** to the `svod` project's agent; the UI is built here
   against the Mock so it compiles and previews without a live engine.

## Out of scope

- Remote (TLS) MCP agent management beyond the loopback token model.
- A built-in chat/generative client inside Svod (this is *access management*, not a
  chat UI).
- Reassigning roles of the engine's own internal author identities.
