#!/usr/bin/env bash
# Install (or remove) the Svod Claude Code hooks for every project on this Mac.
#
#   Scripts/install-claude-hooks.sh              install / update
#   Scripts/install-claude-hooks.sh --uninstall  remove
#
# Copies capture-session.sh and session-start-rulebook.sh to ~/.claude/hooks/svod/ and registers
# them in ~/.claude/settings.json: capture on Stop, PreCompact and SessionEnd, the rule book on
# SessionStart. Entries are recognised by their command path, so running it again replaces its own
# entries instead of adding duplicates, and --uninstall removes only those. Every other hook and
# setting is left as it was. The settings file is backed up next to itself before any change.
set -euo pipefail

mode="install"
case "${1:-}" in
  "") ;;
  --uninstall) mode="uninstall" ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")/../.claude/hooks" && pwd)"
DEST="$HOME/.claude/hooks/svod"
SETTINGS="$HOME/.claude/settings.json"
CAPTURE="$DEST/capture-session.sh"
RULEBOOK="$DEST/session-start-rulebook.sh"

if [ -f "$SETTINGS" ]; then
  # Never rewrite a file we cannot parse — that would drop whatever is in it.
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 \
    || { echo "$SETTINGS is not a JSON object; fix it first, nothing was changed" >&2; exit 1; }
  backup="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)-$$"
  cp -p "$SETTINGS" "$backup"
  echo "Backed up $SETTINGS to $backup"
  current="$(cat "$SETTINGS")"
else
  [ "$mode" = "uninstall" ] && { echo "No $SETTINGS; nothing to remove."; exit 0; }
  current='{}'
fi

# Drop our entries (by script path) from every event, then any group or event left empty.
REMOVE='
  def ours: (.command // "") as $c | ($c | contains($capture)) or ($c | contains($rulebook));
  if (.hooks | type) == "object" then
    .hooks |= (with_entries(
                 .value |= map(if (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end
                               | select((.hooks | type) != "array" or (.hooks | length) > 0)))
               | with_entries(select((.value | length) > 0)))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end'

ADD='
  def entry($cmd; $timeout): {hooks: [{type: "command", command: $cmd, timeout: $timeout}]};
  ("bash \"" + $capture + "\"") as $cap
  | ("bash \"" + $rulebook + "\"") as $rb
  | .hooks = (.hooks // {})
  | .hooks.Stop         = ((.hooks.Stop // [])         + [entry($cap; 30)])
  | .hooks.PreCompact   = ((.hooks.PreCompact // [])   + [entry($cap; 30)])
  | .hooks.SessionEnd   = ((.hooks.SessionEnd // [])   + [entry($cap; 30)])
  | .hooks.SessionStart = ((.hooks.SessionStart // []) + [entry($rb; 10)])'

filter="$REMOVE"
[ "$mode" = "install" ] && filter="$REMOVE | $ADD"

updated="$(printf '%s' "$current" | jq --arg capture "$CAPTURE" --arg rulebook "$RULEBOOK" "$filter")"

if [ "$mode" = "install" ]; then
  mkdir -p "$DEST"
  install -m 0755 "$SRC/capture-session.sh" "$CAPTURE"
  install -m 0755 "$SRC/session-start-rulebook.sh" "$RULEBOOK"
fi

mkdir -p "$(dirname "$SETTINGS")"
tmp="$(mktemp "$SETTINGS.tmp.XXXXXX")"
printf '%s\n' "$updated" > "$tmp"
if [ -f "$SETTINGS" ]; then chmod "$(stat -f %Lp "$SETTINGS")" "$tmp"; fi
mv "$tmp" "$SETTINGS"

if [ "$mode" = "uninstall" ]; then
  rm -f "$CAPTURE" "$RULEBOOK"
  rmdir "$DEST" 2>/dev/null || true
  echo "Removed the Svod hooks from $SETTINGS."
else
  echo "Installed the Svod hooks: capture on Stop/PreCompact/SessionEnd, rule book on SessionStart."
  echo "Optional environment for the rule book: SVOD_ENGINE_URL, SVOD_VAULT, SVOD_API_KEY_FILE."
fi
