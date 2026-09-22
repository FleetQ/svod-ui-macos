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
# no-ops silently when the engine is down. Scope: every project — Scripts/install-claude-hooks.sh wires
# it in ~/.claude/settings.json, and each session is labelled with its own project (below).

# SVOD_CAPTURE=off: our own headless jobs (recall-distill.sh, project-narrative.py) export it for the
# `claude -p` they start. Claude Code passes its environment to hooks, so those runs are not captured.
# Without this the distiller was recorded as a session (19 of 372 on 2026-09-22) and a job that reads
# sessions would read its own previous runs.
[ "${SVOD_CAPTURE:-}" = "off" ] && exit 0

ENGINE="${SVOD_ENGINE_URL:-http://127.0.0.1:7619}"
STATE_DIR="${SVOD_CAPTURE_STATE_DIR:-${TMPDIR:-/tmp}/svod-capture}"

command -v jq  >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
[ -z "$payload" ] && exit 0

sid="$(printf '%s' "$payload"   | jq -r '.session_id // empty' 2>/dev/null || true)"
tpath="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$payload"   | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$sid" ] && exit 0
[ -z "$tpath" ] || [ ! -f "$tpath" ] && exit 0

# The project is the session directory's git remote `origin` as host/owner/repo, lowercase, so the
# same repository gets one label whether it was cloned over https or ssh, and wherever it lives on
# disk. Without a remote it is the directory's name.
#   git@github.com:FleetQ/svod-engine.git          → github.com/fleetq/svod-engine
#   https://user:token@github.com/FleetQ/svod-engine → github.com/fleetq/svod-engine (credentials dropped)
#   ssh://git@github.com:22/FleetQ/svod-engine.git  → github.com/fleetq/svod-engine
dir="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
PROJECT=""
if command -v git >/dev/null 2>&1; then
  url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
  if [ -n "$url" ]; then
    case "$url" in
      *://*) rest="${url#*://}"
             hostpart="${rest%%/*}"; path="${rest#"$hostpart"}"
             hostpart="${hostpart##*@}"; hostpart="${hostpart%%:*}"
             url="$hostpart$path" ;;
      *:*)   hostpart="${url%%:*}"; path="${url#*:}"
             url="${hostpart##*@}/${path#/}" ;;
    esac
    url="${url%/}"; url="${url%.git}"
    # A local-path remote (/srv/git/x, file:///x) has no host — fall back to the directory name.
    case "$url" in /*|.*) ;; */*) PROJECT="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" ;; esac
  fi
fi
[ -z "$PROJECT" ] && PROJECT="$(basename "$dir")"
# The session id names the state file — refuse anything that could leave STATE_DIR.
case "$sid" in *[!A-Za-z0-9._-]*|.*) exit 0 ;; esac

# The JSONL transcript compacted to plain "role: text", without tool-call noise and without the
# compaction summaries (they restate turns the transcript still holds).
#
# The transcript never passes through the shell as an argument or as raw jq input. As `--arg` a
# transcript over ARG_MAX (~1 MB) stopped jq from starting, so such a session was never captured;
# as raw input (`jq -R`) jq split multi-byte UTF-8 at its read-buffer boundaries and corrupted
# Cyrillic text. So both the body and the byte count come straight from the JSONL file, through
# the same filter, and the count is exactly what the engine compares (UTF-8 bytes of the string).
TRANSCRIPT='[ .[]
    | select(.type=="user" or .type=="assistant")
    | select(.isCompactSummary != true)
    | ((.message.role // .type)) as $role
    | ( .message.content
        | if type=="array"  then [ .[] | .text // empty ] | join("\n")
          elif type=="string" then .
          else "" end ) as $text
    | select($text != "")
    | "\($role): \($text)"
  ] | join("\n\n")'

bytes="$(jq -rs "($TRANSCRIPT) | utf8bytelength" "$tpath" 2>/dev/null || true)"
case "$bytes" in ''|*[!0-9]*|0) exit 0 ;; esac
state="$STATE_DIR/$sid"

if [ "$event" != "PreCompact" ] && [ "$event" != "SessionEnd" ] && [ -f "$state" ]; then
  last="$(cat "$state" 2>/dev/null || true)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ "$bytes" -lt $(( last * 2 )) ]; then exit 0; fi
fi

now_ms=$(( $(date +%s) * 1000 ))
started_ms=$now_ms
if bt="$(stat -f %B "$tpath" 2>/dev/null)"; then started_ms=$(( bt * 1000 )); fi

body="$(jq -cs --arg sid "$sid" --arg project "$PROJECT" \
  --argjson started "$started_ms" --argjson ended "$now_ms" \
  '{sessionId:$sid, project:$project, transcript:('"$TRANSCRIPT"'), startedAt:$started, endedAt:$ended}' \
  "$tpath" 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Record the size only when the engine accepted the capture, so a failed post (engine down, or a
# 409 when another capture of this session landed first) is retried on the next event.
if printf '%s' "$body" | curl -sf -m 10 -o /dev/null -X POST "$ENGINE/api/v1/memory/capture" \
     -H 'Content-Type: application/json' --data-binary @- 2>/dev/null; then
  if [ "$event" = "SessionEnd" ]; then
    rm -f "$state"
  else
    mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s' "$bytes" > "$state" 2>/dev/null
  fi
fi
exit 0
