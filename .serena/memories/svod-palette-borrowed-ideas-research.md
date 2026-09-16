# Palette (palette.team) evaluation — research only, nothing implemented (2026-09-05)

Report: `claudedocs/research_palette-team_2026-09-05.md`. Same method as `mem:svod-claude-mem-borrowed-ideas` and `mem:svod-recall-memory-sprint`: ground each "idea" in what Svod already has before scoping.

**What Palette is:** macOS app hosting agent chats (Claude Code, Codex, Gemini, Mistral, own harness) over a markdown folder; a *session* is a sandbox clone, human reviews a diff and "saves back". Built for teams on Drive/Dropbox, not engineers. Palette OS (Context Library, Skills, Handoffs, Connector Gateway) is private preview only.

**Verdict:** Svod is ahead on infrastructure (retrieval, GraphRAG, git history/merge, Sources, multi-machine sync, MCP agent-agnostic). Palette is ahead on the human workflow around agent writes and a few cheap UX bits.

**Ranked ideas (operator decides):**
- A1 Post-hoc review of agent commits — Activity today has only "jump" (`ActivityFeedView.swift:122`), History has Restore. Light variant: reviewed/unreviewed + diff + Revert in Activity. Heavy variant: `WRITE_STAGED` agent role → `refs/svod/staging/<agentId>`, Accept/Discard. Recommended: light first.
- A2 HTML preview in the web editor — verified absent (only comments mention html in `Svod/`; `editor.src.js` has no HTML render mode). Small: third mode off `setLanguage`, sandboxed iframe.
- B3 Pinned notes in sidebar — Saved Searches exist (`SidebarView.swift:404`), pinned notes don't.
- B4 Agent prompts stored in the vault (`_svod/agents/<id>.md`) instead of engine config JSON → versioned/searchable.
- B5 Vault templates in Create Vault. C6 human override of graph theme summaries. C7 typed `handoff` note kind.

**Already have / don't want:** conflicts+merge, References≈Sources, per-agent roles, frontmatter form, history restore; NOT in-app chat or an embedded LLM (engine = data plane decision), NOT team sharing via Dropbox (would be a pivot).
