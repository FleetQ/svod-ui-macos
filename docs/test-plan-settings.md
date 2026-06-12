# Settings — Test Plan

Manual + preview-driven (no XCTest target in this personal app). Each panel ships
SwiftUI #Previews; verification is build-green + previews + live-engine smoke.

## Acceptance criteria
- AC-1 ⌘, opens the Settings window; sections navigable by keyboard; VoiceOver labels.
- AC-2 Theme = Light/System/Dark re-themes the whole app **live**; both themes WCAG-AA.
- AC-3 Endpoint change → app reconnects to the new host:port; toolbar pill reflects it;
  value survives relaunch; bad input is rejected with a message.
- AC-4 Start/Restart/Stop run the correct `launchctl` verb; connection state transitions;
  "agent not installed" surfaces a clear error (no crash).
- AC-5 Sync status shows role/last-head/conflicts when `metrics.sync` present, else
  "sync not active".
- AC-6 Autosave on → edits persist after debounce; a stale write still raises the 3-way
  merge (never silent overwrite).
- AC-7 Search default mode/limit are honored by ⌘K on next open.
- AC-8 Activity type filters hide/show event kinds live; feed cap respected.
- AC-9 (v2) When engine lacks an endpoint, the Sync/Backup control renders disabled with
  a "needs engine support" note — never a dead/erroring control.
- AC-10 (v2) When supported: setting a backup remote persists engine-side; "Back up now"
  returns an ack; secrets entered only as `keychain:`/`env:` references.

## Edge cases
- Empty/invalid host or port (0, >65535, non-numeric) → rejected.
- Endpoint points at a down engine → offline state + Start affordance, no crash.
- Theme = System while OS toggles appearance → tokens follow.
- Autosave debounce vs rapid typing → one write, not many; cancel in-flight on new edit.
- Reduce Motion on → feed animation + graph respect it regardless of toggle.
- Settings changed while disconnected → persisted, applied on reconnect.
- v2: engine returns 501 → `.notImplemented` mapped, panel degrades, no error toast.
- v2: backup remote with a raw secret typed in → rejected client-side (must be a ref).

## Smoke (live engine on :7517)
- Launch → connect; change a search default → ⌘K reflects it; toggle theme → re-themes;
  open Engine panel → real vault path / embedder / index docCount shown; Stop → engine
  goes down, Start → comes back.
