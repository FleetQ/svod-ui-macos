#!/usr/bin/env bash
# Svod "recall" — nightly distiller (the LLM compute step of the recall loop).
#
# THE SCRIPT does all the HTTP; the agent only reads local files and writes notes.
#
# It used to hand the agent the engine's URL and let it call the API itself. Measured on the first
# real run: that cannot work. `claude -p` runs under this machine's global PreToolUse hooks, which
# intercept curl/WebFetch and route them at the context-mode MCP server — and in a headless run that
# server is not connected. The agent therefore had NO way to make an HTTP call and concluded the
# engine was unreachable, while the engine was answering /ready 200 the whole time. So the loop
# reported success nightly and wrote nothing.
#
# Notes are written straight into the vault directory with the Write tool: the engine's FileWatcher
# ingests and commits them, so no HTTP and no MCP are needed on the agent's side either.
#
# Invoked nightly by launchd (Scripts/dev.svod.recall-distill.plist). Best-effort: logs to
# ~/Library/Logs/svod/recall-distill.log and never errors out the agent.

set -uo pipefail

PROJECT_DIR="${SVOD_UI_DIR:-$HOME/htdocs/svod-ui-macos}"
PROMPT="$PROJECT_DIR/.claude/hooks/recall-distill-prompt.md"
MODEL="${RECALL_DISTILL_MODEL:-claude-haiku-4-5}"
ENGINE="${SVOD_ENGINE:-http://127.0.0.1:7619}"
VAULT_ID="${SVOD_VAULT:-personal}"
BATCH="${RECALL_DISTILL_BATCH:-25}"
LOG_DIR="$HOME/Library/Logs/svod"
LOG="$LOG_DIR/recall-distill.log"

mkdir -p "$LOG_DIR"
log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# launchd does NOT source a login shell, so the PATH here is the bare system one and `claude`
# — installed under $HOME — is invisible. Measured: the first real run logged "claude CLI not found;
# skip" and exited 0, which is how a nightly job silently does nothing forever while looking healthy.
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
  for candidate in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.claude/local/claude"; do
    [ -x "$candidate" ] && { CLAUDE_BIN="$candidate"; break; }
  done
fi
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -n "$CLAUDE_BIN" ] || { log "claude CLI not found (looked in ~/.local/bin, homebrew, /usr/local/bin, PATH); skip"; exit 0; }
[ -f "$PROMPT" ] || { log "prompt missing; skip"; exit 0; }

# 1. Engine reachable? A failure here is the honest "skip", unlike the agent's guess.
if ! curl -sf -m 5 "$ENGINE/ready" >/dev/null 2>&1; then
  log "engine $ENGINE not ready; skip"
  exit 0
fi

VAULT_PATH="$(curl -sf -m 5 "$ENGINE/api/v1/settings?vault=$VAULT_ID" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("vaultPath",""))' 2>/dev/null)"
[ -n "$VAULT_PATH" ] || { log "could not resolve vault path for '$VAULT_ID'; skip"; exit 0; }

# 2. Pull the undistilled batch and every session body into a work dir.
#
# INSIDE the project dir, not $TMPDIR. Measured: with the work dir under /var/folders the agent
# could not read it at all — a headless `claude -p` cannot grant itself file access outside its
# working directory, so it reported "permissions blocked" and wrote nothing. The vault is outside
# too, which is why notes are written here and copied into the vault by this script (step 4).
WORK="$(mktemp -d "$PROJECT_DIR/.recall-work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SESSIONS="$WORK/sessions.json"
curl -sf -m 20 "$ENGINE/api/v1/memory/sessions?vault=$VAULT_ID&distilled=false&limit=$BATCH" -o "$SESSIONS" \
  || { log "could not list sessions; skip"; exit 0; }

COUNT="$(/usr/bin/python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$SESSIONS" 2>/dev/null || echo 0)"
if [ "$COUNT" = "0" ]; then
  log "no undistilled sessions; done"
  exit 0
fi

/usr/bin/python3 - "$SESSIONS" "$WORK" "$ENGINE" "$VAULT_ID" <<'PY' >>"$LOG" 2>&1
import json, subprocess, sys, os, urllib.parse
sessions, work, engine, vault = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(os.path.join(work, "sessions"), exist_ok=True)
kept = []
for s in json.load(open(sessions)):
    path = s["path"]
    url = f"{engine}/api/v1/file?vault={vault}&path=" + urllib.parse.quote(path, safe="")
    out = subprocess.run(["curl", "-sf", "-m", "20", url], capture_output=True, text=True)
    if out.returncode != 0:
        continue
    try:
        body = json.loads(out.stdout).get("content", "")
    except Exception:
        continue
    name = path.replace("/", "_")
    with open(os.path.join(work, "sessions", name), "w") as f:
        f.write(body)
    kept.append({"path": path, "file": name, "project": s.get("project"), "bytes": s.get("bytes")})
json.dump(kept, open(os.path.join(work, "batch.json"), "w"), indent=1)
print(f"fetched {len(kept)} session bodies")
PY

# 3. Distil. The agent sees only local paths; it writes notes into the vault directly (the engine's
#    watcher commits them) and leaves a manifest behind for step 4.
log "recall-distill start (model=$MODEL, bin=$CLAUDE_BIN, sessions=$COUNT)"
cd "$PROJECT_DIR" || exit 0
PROMPT_TEXT="$(cat "$PROMPT")
--- RUNTIME CONTEXT (this run) ---
WORK_DIR:      $WORK
BATCH_INDEX:   $WORK/batch.json   (list of {path, file, project, bytes})
SESSION_BODIES:$WORK/sessions/    (read these; do NOT call any HTTP API)
NOTES_OUT:     $WORK/notes/       (write your distilled notes HERE, one .md per session)
MANIFEST_OUT:  $WORK/manifest.json"

mkdir -p "$WORK/notes"
# Time-boxed. A nightly job that can hang forever is worse than one that fails: launchd would keep
# the slot occupied and the next night's run would never start. `timeout` is not on stock macOS, so
# this is a plain watchdog.
"$CLAUDE_BIN" -p "$PROMPT_TEXT" --model "$MODEL" --permission-mode acceptEdits >>"$LOG" 2>&1 &
CLAUDE_PID=$!
( sleep "${RECALL_DISTILL_TIMEOUT:-1800}"; kill -TERM "$CLAUDE_PID" 2>/dev/null ) &
WATCHDOG=$!
wait "$CLAUDE_PID" || log "claude -p exited non-zero or timed out (best-effort)"
kill "$WATCHDOG" 2>/dev/null

# 4. Copy the notes into the vault (the engine's watcher ingests + commits them), then record the
#    outcome through the API — again from here, not from the agent.
if [ -d "$WORK/notes" ] && [ -n "$(ls -A "$WORK/notes" 2>/dev/null)" ]; then
  mkdir -p "$VAULT_PATH/messy/recall"
  cp -n "$WORK/notes/"*.md "$VAULT_PATH/messy/recall/" 2>/dev/null || true
  log "copied $(ls -1 "$WORK/notes"/*.md 2>/dev/null | wc -l | tr -d ' ') note(s) into the vault"
fi

if [ -f "$WORK/manifest.json" ]; then
  /usr/bin/python3 - "$WORK/manifest.json" "$ENGINE" "$VAULT_ID" <<'PY' >>"$LOG" 2>&1
import json, subprocess, sys
manifest, engine, vault = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(manifest))
def post(path, body):
    return subprocess.run(
        ["curl", "-sf", "-m", "20", "-X", "POST", f"{engine}{path}?vault={vault}",
         "-H", "content-type: application/json", "-d", json.dumps(body)],
        capture_output=True, text=True)
# `noteRefs` is List<String> on the engine side — a null element 400s the WHOLE request, so one
# manifest entry without a note used to lose the entire batch. Measured: 10 sessions silently
# stayed undistilled with `rc=22` while the proposals beside them posted fine.
done = [d for d in m.get("distilled", []) if d.get("path") and d.get("noteRef")]
dropped = len(m.get("distilled", [])) - len(done)
if dropped:
    print(f"dropped {dropped} manifest entr(ies) with no noteRef — those sessions stay undistilled")
if done:
    r = post("/api/v1/memory/sessions/mark-distilled",
             {"paths": [d["path"] for d in done], "noteRefs": [d["noteRef"] for d in done]})
    print(f"marked {len(done)} distilled (rc={r.returncode}) {r.stdout.strip()[:120]}")
for p in m.get("proposals", []):
    r = post("/api/v1/memory/proposals", p)
    print(f"proposal '{p.get('title')}' (rc={r.returncode})")
PY
else
  log "no manifest written — nothing marked distilled"
fi

log "recall-distill done"
exit 0
