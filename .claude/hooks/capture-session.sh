#!/usr/bin/env bash
# Svod "recall" — session capture (Claude Code Stop hook).
#
# Reads the Stop-hook payload on stdin and POSTs the raw session transcript to the
# Svod engine's /api/v1/memory/capture endpoint, which stores it under
# messy/sessions/ (kept OUT of search/recall). NO LLM call — this is the free
# "capture" step of the recall loop; distillation happens later, out of band.
#
# Best-effort by design: it must NEVER block or fail a session. Every path exits 0,
# and it no-ops silently when the engine is down or the endpoint predates 0.22.0.
# Scope: this project only (wired in .claude/settings.json here).

ENGINE="${SVOD_ENGINE_URL:-http://127.0.0.1:7619}"
PROJECT="svod-ui-macos"

command -v jq  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[ -z "$payload" ] && exit 0

sid="$(printf '%s' "$payload"  | jq -r '.session_id // empty' 2>/dev/null || true)"
tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -z "$sid" ] && exit 0
[ -z "$tpath" ] || [ ! -f "$tpath" ] && exit 0

# Compact the JSONL transcript to plain "role: text", dropping tool-call noise.
transcript="$(jq -rs '
  [ .[]
    | select(.type=="user" or .type=="assistant")
    | ((.message.role // .type)) as $role
    | ( .message.content
        | if type=="array"  then [ .[] | .text // empty ] | join("\n")
          elif type=="string" then .
          else "" end ) as $text
    | select($text != "")
    | "\($role): \($text)"
  ] | join("\n\n")
' "$tpath" 2>/dev/null || true)"
[ -z "$transcript" ] && exit 0

now_ms=$(( $(date +%s) * 1000 ))
started_ms=$now_ms
if bt="$(stat -f %B "$tpath" 2>/dev/null)"; then started_ms=$(( bt * 1000 )); fi

body="$(jq -n --arg sid "$sid" --arg project "$PROJECT" --arg t "$transcript" \
  --argjson started "$started_ms" --argjson ended "$now_ms" \
  '{sessionId:$sid, project:$project, transcript:$t, startedAt:$started, endedAt:$ended}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

curl -s -m 5 -X POST "$ENGINE/api/v1/memory/capture" \
  -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1 || true
exit 0
