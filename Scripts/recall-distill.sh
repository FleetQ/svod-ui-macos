#!/usr/bin/env bash
# Svod "recall" — nightly distiller (the LLM compute step of the recall loop).
#
# Thin wrapper: runs headless `claude -p` with the distill prompt, in the project
# dir so it inherits the project's MCP config (svod bridge) + the local engine.
# Locked to a cheap model to keep cost low (recall targets ≈ $0.85/night). All the
# intelligence lives in .claude/hooks/recall-distill-prompt.md.
#
# Invoked nightly by launchd (Scripts/dev.svod.recall-distill.plist). Best-effort:
# logs to ~/Library/Logs/svod/recall-distill.log and never errors out the agent.

set -uo pipefail

PROJECT_DIR="${SVOD_UI_DIR:-$HOME/htdocs/svod-ui-macos}"
PROMPT="$PROJECT_DIR/.claude/hooks/recall-distill-prompt.md"
MODEL="${RECALL_DISTILL_MODEL:-claude-haiku-4-5}"
LOG_DIR="$HOME/Library/Logs/svod"
LOG="$LOG_DIR/recall-distill.log"

mkdir -p "$LOG_DIR"
command -v claude >/dev/null 2>&1 || { echo "$(date '+%F %T') claude CLI not found; skip" >>"$LOG"; exit 0; }
[ -f "$PROMPT" ] || { echo "$(date '+%F %T') prompt missing; skip" >>"$LOG"; exit 0; }

echo "$(date '+%F %T') recall-distill start (model=$MODEL)" >>"$LOG"
cd "$PROJECT_DIR" || exit 0
# Headless, non-interactive, permissioned for its own tools. Time-boxed by launchd.
claude -p "$(cat "$PROMPT")" --model "$MODEL" --permission-mode acceptEdits >>"$LOG" 2>&1 || \
  echo "$(date '+%F %T') recall-distill claude -p exited non-zero (best-effort)" >>"$LOG"
echo "$(date '+%F %T') recall-distill done" >>"$LOG"
exit 0
