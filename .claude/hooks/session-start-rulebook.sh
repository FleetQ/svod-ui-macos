#!/usr/bin/env bash
# Svod rule book — Claude Code SessionStart hook.
#
# Prints the vault's confirmed policies and preferences as a short index inside a
# <svod-rulebook> block; Claude Code adds a SessionStart hook's stdout to the session context.
# It is an index, not the notes: one line per rule, at most 40 lines and 6,000 characters, so
# every session pays a small fixed cost. The model reads a note when a rule applies. It also says
# how many memories are waiting for a person to approve them in the Svod app.
#
# Environment:
#   SVOD_ENGINE_URL    engine base URL (default http://127.0.0.1:7619)
#   SVOD_VAULT         vault id (default: the engine's default vault)
#   SVOD_API_KEY_FILE  file holding a personal API key, for a central engine
#
# Best-effort by design: it must NEVER block or fail a session. Every path exits 0. When the
# engine is down or slow (2 s) it prints nothing. A refused key (401/403) prints one notice line,
# so a bad key does not look the same as "no rules".

ENGINE="${SVOD_ENGINE_URL:-http://127.0.0.1:7619}"
MAX_LINES=40
MAX_CHARS=6000

command -v jq  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

cat >/dev/null 2>&1 || true   # the hook payload is not needed

query="types=policy,preference&limit=$MAX_LINES"
if [ -n "${SVOD_VAULT:-}" ]; then
  query="$query&vault=$(jq -rn --arg v "$SVOD_VAULT" '$v|@uri' 2>/dev/null || true)"
fi

# The key goes to curl on stdin, never as an argument other processes could read.
key=""
if [ -n "${SVOD_API_KEY_FILE:-}" ] && [ -r "$SVOD_API_KEY_FILE" ]; then
  key="$(tr -d '[:space:]' < "$SVOD_API_KEY_FILE" 2>/dev/null || true)"
fi

response="$(
  if [ -n "$key" ]; then printf 'Authorization: Bearer %s\n' "$key"; fi |
    curl -s -m 2 -H @- -w '\n%{http_code}' "$ENGINE/api/v1/memory/rulebook?$query" 2>/dev/null
)" || exit 0

status="${response##*$'\n'}"
body="${response%$'\n'*}"

case "$status" in
  200) ;;
  401|403)
    echo "Svod rule book unavailable: the engine refused the API key (HTTP $status). Check SVOD_API_KEY_FILE."
    exit 0 ;;
  *) exit 0 ;;
esac

# Text from the vault must not be able to close the block or open a new one, and each entry
# stays on one line.
printf '%s' "$body" | jq -r --argjson maxLines "$MAX_LINES" --argjson maxChars "$MAX_CHARS" '
  def clean: tostring
    | gsub("[\r\n\t]+"; " ")
    | gsub("<(?<rest>\\s*/?\\s*svod-rulebook)"; "&lt;\(.rest)"; "i");
  def cut($n): if length > $n then .[0:$n - 1] + "…" else . end;

  ((.awaitingReview // 0) | if type == "number" and . > 0 then floor else 0 end) as $waiting
  | [ (.items // [])[:$maxLines][]
      | "- [\(.type // "memory" | clean)] \(.title // "" | clean | cut(200))"
        + (if ((.summary // "") | clean) != "" then " — \(.summary | clean | cut(300))" else "" end)
        + " (\(.path // "" | clean | cut(300)))" ] as $lines
  | if ($lines | length) == 0 and $waiting == 0 then empty else
      "<svod-rulebook>" as $open
      | "Svod rule book: confirmed policies and preferences from the vault. Each line is an index entry; read the note (Svod MCP `read`) when it applies." as $intro
      | (if $waiting > 0 then "\($waiting) memories await review in the Svod app." else null end) as $notice
      | "</svod-rulebook>" as $close
      | ([$open, $intro, $notice, $close] | map(select(. != null) | length + 1) | add) as $fixed
      | (reduce $lines[] as $l ({used: $fixed, out: []};
          if .used + ($l | length) + 1 <= $maxChars then {used: (.used + ($l | length) + 1), out: (.out + [$l])} else . end)
        | .out) as $kept
      | ([$open, $intro] + $kept + (if $notice then [$notice] else [] end) + [$close]) | join("\n")
    end
' 2>/dev/null || true
exit 0
