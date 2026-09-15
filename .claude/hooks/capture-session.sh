#!/usr/bin/env bash
# Svod "recall" — session capture (Claude Code Stop, PreCompact and SessionEnd hooks).
#
# Reads the hook payload on stdin and POSTs the session transcript to the Svod engine's
# /api/v1/memory/capture endpoint, which stores it under messy/sessions/ (kept OUT of
# search/recall). NO LLM call — this is the free "capture" step of the recall loop;
# distillation happens later, out of band.
#
# The engine keeps ONE note per session and rewrites it when a larger transcript arrives
# (engine 1.22.0+). Before that it kept the first capture and ignored the rest, and this
# hook ran only on Stop — so every stored session was its first response and nothing more.
#
# When it posts:
#   PreCompact, SessionEnd  always — the last chance before the transcript is rewritten or closed.
#   Stop                    on the first capture of a session, then only once the transcript has
#                           at least doubled since the last accepted capture. Every accepted
#                           capture is a git commit of the whole transcript; posting on every
#                           response would commit a multi-hour session hundreds of times.
# A session killed without SessionEnd keeps what the last doubling captured.
#
# Best-effort by design: it must NEVER block or fail a session. Every path exits 0, and it
# no-ops silently when the engine is down. Scope: this project only (wired in .claude/settings.json).

ENGINE="${SVOD_ENGINE_URL:-http://127.0.0.1:7619}"
PROJECT="svod-ui-macos"
STATE_DIR="${SVOD_CAPTURE_STATE_DIR:-${TMPDIR:-/tmp}/svod-capture}"

command -v jq  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[ -z "$payload" ] && exit 0

sid="$(printf '%s' "$payload"   | jq -r '.session_id // empty' 2>/dev/null || true)"
tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ -z "$sid" ] && exit 0
[ -z "$tpath" ] || [ ! -f "$tpath" ] && exit 0
# The session id names the state file — refuse anything that could leave STATE_DIR.
case "$sid" in *[!A-Za-z0-9._-]*|.*) exit 0 ;; esac

# Compact the JSONL transcript to plain "role: text", dropping tool-call noise and the
# compaction summaries (they restate turns the transcript still holds).
transcript="$(jq -rs '
  [ .[]
    | select(.type=="user" or .type=="assistant")
    | select(.isCompactSummary != true)
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

bytes="$(printf '%s' "$transcript" | wc -c | tr -d ' ')"
state="$STATE_DIR/$sid"

if [ "$event" != "PreCompact" ] && [ "$event" != "SessionEnd" ] && [ -f "$state" ]; then
  last="$(cat "$state" 2>/dev/null || true)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ "$bytes" -lt $(( last * 2 )) ]; then exit 0; fi
fi

now_ms=$(( $(date +%s) * 1000 ))
started_ms=$now_ms
if bt="$(stat -f %B "$tpath" 2>/dev/null)"; then started_ms=$(( bt * 1000 )); fi

body="$(jq -n --arg sid "$sid" --arg project "$PROJECT" --arg t "$transcript" \
  --argjson started "$started_ms" --argjson ended "$now_ms" \
  '{sessionId:$sid, project:$project, transcript:$t, startedAt:$started, endedAt:$ended}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Record the size only when the engine accepted the capture, so a failed post is retried next time.
if printf '%s' "$body" | curl -sf -m 10 -o /dev/null -X POST "$ENGINE/api/v1/memory/capture" \
     -H 'Content-Type: application/json' --data-binary @- 2>/dev/null; then
  if [ "$event" = "SessionEnd" ]; then
    rm -f "$state"
  else
    mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$bytes" > "$state" 2>/dev/null
  fi
fi
exit 0
