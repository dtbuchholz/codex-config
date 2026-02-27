#!/bin/bash
# Memory rollup - invoked by launchd weekly
# Runs Codex non-interactively to review and consolidate memory files.

set -euo pipefail

LOG_DIR="$HOME/.codex/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/memory-rollup.log"

# Load environment (reuse existing OpenRouter credentials if present)
ENV_FILE_CLAUDE="$HOME/.claude/scripts/openrouter.conf"
ENV_FILE_CODEX="$HOME/.codex/scripts/openrouter.conf"
if [ -f "$ENV_FILE_CODEX" ]; then
  set -a
  source "$ENV_FILE_CODEX"
  set +a
elif [ -f "$ENV_FILE_CLAUDE" ]; then
  set -a
  source "$ENV_FILE_CLAUDE"
  set +a
fi

echo "=== Memory Rollup: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$LOG_FILE"
SUCCESS=0
for ATTEMPT in 1 2 3; do
  echo "Attempt $ATTEMPT/3" >> "$LOG_FILE"
  if /opt/homebrew/bin/codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -C "$HOME/.codex" \
    "/memory-rollup" \
    >> "$LOG_FILE" 2>&1; then
    SUCCESS=1
    break
  fi
  echo "Attempt $ATTEMPT failed" >> "$LOG_FILE"
  sleep 10
done

if [ "$SUCCESS" -eq 1 ]; then
  echo "=== Completed: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$LOG_FILE"
else
  echo "=== Failed: $(date -u '+%Y-%m-%d %H:%M:%S UTC') ===" >> "$LOG_FILE"
  exit 1
fi
echo "" >> "$LOG_FILE"
