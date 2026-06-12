# Settings — Design (Think)

Builds on `docs/settings-requirements.md`. Forcing questions:

- **Who needs this & what do they do today?** The single user, running a local Svod
  engine. Today everything is hardcoded: forced dark, fixed `127.0.0.1:7517`, no way
  to change the editor/search/feed behavior, no engine controls beyond "Start Svod",
  no visibility into sync/backup.
- **Narrowest MVP worth shipping (v1)?** A native macOS Settings window (⌘,) that
  (1) points the UI at the right engine + controls its lifecycle, (2) shows sync
  health, (3) lets the user pick theme and tune editor/search/feed. Zero engine
  changes required.
- **What makes someone say "whoa"?** Theme switches the whole app live; changing the
  endpoint reconnects instantly; Start/Restart/Stop the engine from the UI; and (v2)
  configure the git backup remote + "Back up now" without touching git.
- **How does it compound?** A `SettingsStore` becomes the single place every feature
  reads its preferences from, so future toggles cost one line. The connection layer
  generalizes to multiple local vaults later.

Decisions taken:
- Theme: ship **Dark / Light / System** in v1 (tokens already adapt; only the forced
  `.preferredColorScheme(.dark)` blocks it).
- Endpoint: single configurable value in v1; named profiles deferred (cheap later).
- v2 sync/backup config is **engine-gated** — delegated to the svod engine agent; the
  UI degrades gracefully (read-only / disabled-with-note) until those endpoints land.
