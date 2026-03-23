#!/bin/bash
# Dev loop orchestrator: Claude implement -> Codex review -> Claude fix -> Claude final review.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ~/.codex/scripts/dev-loop.sh [--project-dir DIR] [--spec FILE] [--max-diff-chars N] [--skip-implement] [--skip-fix]

Options:
  -C, --project-dir DIR   Project directory (default: current working directory)
  -s, --spec FILE         Spec file path (default: <project>/SPEC.md)
      --max-diff-chars N  Max diff chars embedded into prompts (default: 60000)
      --skip-implement    Skip Phase 1 (Claude implement)
      --skip-fix          Skip Phase 3 (Claude apply fixes)
  -h, --help              Show this help
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

to_abs() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

extract_claude_text() {
  jq -r '
    select(.type=="assistant")
    | .message.content[]?
    | if type=="object" then (.text // empty) else . end
  '
}

extract_codex_text() {
  jq -r '
    select(.type=="item.completed" and .item.type=="agent_message")
    | .item.text
  '
}

PROJECT_DIR="$(pwd)"
SPEC_FILE=""
MAX_DIFF_CHARS=60000
SKIP_IMPLEMENT=0
SKIP_FIX=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C|--project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    -s|--spec)
      SPEC_FILE="$2"
      shift 2
      ;;
    --max-diff-chars)
      MAX_DIFF_CHARS="$2"
      shift 2
      ;;
    --skip-implement)
      SKIP_IMPLEMENT=1
      shift
      ;;
    --skip-fix)
      SKIP_FIX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

PROJECT_DIR="$(to_abs "$PROJECT_DIR")"
if [[ -z "$SPEC_FILE" ]]; then
  SPEC_FILE="$PROJECT_DIR/SPEC.md"
fi
SPEC_FILE="$(to_abs "$SPEC_FILE")"

require_cmd jq
require_cmd git
require_cmd claude
require_cmd codex

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo "Project is not a git repo: $PROJECT_DIR" >&2
  exit 1
fi
if [[ ! -f "$SPEC_FILE" ]]; then
  echo "Spec file not found: $SPEC_FILE" >&2
  exit 1
fi
if ! [[ "$MAX_DIFF_CHARS" =~ ^[0-9]+$ ]]; then
  echo "--max-diff-chars must be an integer" >&2
  exit 1
fi

RUN_DIR="$PROJECT_DIR/.dev-loop"
mkdir -p "$RUN_DIR"

HANDOFF_FILE="$RUN_DIR/phase1-handoff.md"
REVIEW_FILE="$RUN_DIR/phase2-review.md"
APPLY_FILE="$RUN_DIR/phase3-apply.md"
FINAL_FILE="$RUN_DIR/phase4-final.md"

DIFF_FULL_FILE="$RUN_DIR/diff-full.patch"
DIFF_TRUNC_FILE="$RUN_DIR/diff-truncated.patch"

truncate_file() {
  local src="$1"
  local dst="$2"
  local limit="$3"
  python3 - "$src" "$dst" "$limit" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
limit = int(sys.argv[3])
if len(src) <= limit:
    out = src
else:
    out = src[:limit] + "\n\n[... DIFF TRUNCATED ...]\n"
Path(sys.argv[2]).write_text(out, encoding="utf-8")
PY
}

echo "Project: $PROJECT_DIR"
echo "Spec:    $SPEC_FILE"
echo "Run dir: $RUN_DIR"
echo ""

if [[ "$SKIP_IMPLEMENT" -eq 0 ]]; then
  echo "=== PHASE 1: Implement (Claude) ==="
  claude --project-dir "$PROJECT_DIR" --output-format stream-json -p "$(cat "$SPEC_FILE")" \
    | tee "$RUN_DIR/phase1-claude.jsonl" \
    | extract_claude_text > "$HANDOFF_FILE"
  if [[ ! -s "$HANDOFF_FILE" ]]; then
    echo "Warning: Phase 1 produced no assistant text." >&2
  fi
else
  echo "=== PHASE 1: Skipped ==="
  : > "$HANDOFF_FILE"
fi

echo "=== PHASE 2: Review (Codex) ==="
git -C "$PROJECT_DIR" diff HEAD > "$DIFF_FULL_FILE"
truncate_file "$DIFF_FULL_FILE" "$DIFF_TRUNC_FILE" "$MAX_DIFF_CHARS"

REVIEW_PROMPT_FILE="$RUN_DIR/phase2-review-prompt.md"
cat > "$REVIEW_PROMPT_FILE" <<EOF
You are reviewing an implementation against a spec.

Return:
1) Critical issues
2) Important improvements
3) Concrete patch guidance

SPEC:
$(cat "$SPEC_FILE")

IMPLEMENTATION NOTES FROM CLAUDE:
$(cat "$HANDOFF_FILE")

CURRENT DIFF (possibly truncated):
$(cat "$DIFF_TRUNC_FILE")
EOF

codex exec --json -C "$PROJECT_DIR" "$(cat "$REVIEW_PROMPT_FILE")" \
  | tee "$RUN_DIR/phase2-codex.jsonl" \
  | extract_codex_text > "$REVIEW_FILE"
if [[ ! -s "$REVIEW_FILE" ]]; then
  echo "Warning: Phase 2 produced no Codex review text." >&2
fi

if [[ "$SKIP_FIX" -eq 0 ]]; then
  echo "=== PHASE 3: Apply Fixes (Claude) ==="
  FIX_PROMPT_FILE="$RUN_DIR/phase3-fix-prompt.md"
  cat > "$FIX_PROMPT_FILE" <<EOF
Apply the following review suggestions directly in the project.
Make code changes, run relevant checks, and summarize exactly what changed.

REVIEW SUGGESTIONS:
$(cat "$REVIEW_FILE")
EOF

  claude --project-dir "$PROJECT_DIR" --output-format stream-json -p "$(cat "$FIX_PROMPT_FILE")" \
    | tee "$RUN_DIR/phase3-claude.jsonl" \
    | extract_claude_text > "$APPLY_FILE"
  if [[ ! -s "$APPLY_FILE" ]]; then
    echo "Warning: Phase 3 produced no assistant text." >&2
  fi
else
  echo "=== PHASE 3: Skipped ==="
  : > "$APPLY_FILE"
fi

echo "=== PHASE 4: Final Review (Claude, fresh pass) ==="
git -C "$PROJECT_DIR" diff HEAD > "$DIFF_FULL_FILE"
truncate_file "$DIFF_FULL_FILE" "$DIFF_TRUNC_FILE" "$MAX_DIFF_CHARS"

FINAL_PROMPT_FILE="$RUN_DIR/phase4-final-prompt.md"
cat > "$FINAL_PROMPT_FILE" <<EOF
Do a final holistic review against the original spec.
Focus on correctness gaps, regressions, missing tests, and operational risk.

ORIGINAL SPEC:
$(cat "$SPEC_FILE")

CODEX REVIEW:
$(cat "$REVIEW_FILE")

FINAL DIFF (possibly truncated):
$(cat "$DIFF_TRUNC_FILE")
EOF

claude --project-dir "$PROJECT_DIR" --output-format stream-json -p "$(cat "$FINAL_PROMPT_FILE")" \
  | tee "$RUN_DIR/phase4-claude.jsonl" \
  | extract_claude_text > "$FINAL_FILE"

echo ""
echo "=== Done ==="
echo "Artifacts:"
echo "  - $HANDOFF_FILE"
echo "  - $REVIEW_FILE"
echo "  - $APPLY_FILE"
echo "  - $FINAL_FILE"
echo ""
echo "Current repo status:"
git -C "$PROJECT_DIR" status --short
