#!/bin/bash
# Block commits/pushes when gitleaks finds potential secrets.

set -euo pipefail

MODE="${1:-commit}" # commit|push

if [ "${SKIP_GITLEAKS:-0}" = "1" ]; then
  echo "[gitleaks] SKIP_GITLEAKS=1 set, skipping secret scan." >&2
  exit 0
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "[gitleaks] BLOCKED: gitleaks is required for commit/push secret scanning." >&2
  echo "Install: brew install gitleaks" >&2
  echo "Temporary bypass (not recommended): SKIP_GITLEAKS=1 git commit|git push ..." >&2
  exit 1
fi

REPORT_DIR=".git/gitleaks"
mkdir -p "$REPORT_DIR"
REPORT_PATH="$REPORT_DIR/${MODE}-$(date +%Y%m%d-%H%M%S).json"

scan_commit() {
  if git diff --cached --quiet; then
    echo "[gitleaks] No staged changes; skipping." >&2
    return 0
  fi

  gitleaks git \
    --staged \
    --redact \
    --report-format json \
    --report-path "$REPORT_PATH"
}

scan_push() {
  local upstream range_count
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"

  if [ -n "$upstream" ]; then
    range_count="$(git rev-list --count "$upstream..HEAD")"
    if [ "$range_count" = "0" ]; then
      echo "[gitleaks] Nothing to push; skipping." >&2
      return 0
    fi

    gitleaks git \
      --redact \
      --log-opts="$upstream..HEAD" \
      --report-format json \
      --report-path "$REPORT_PATH"
  else
    # No upstream: scan recent commit history on this branch.
    gitleaks git \
      --redact \
      --log-opts="--max-count=100 HEAD" \
      --report-format json \
      --report-path "$REPORT_PATH"
  fi
}

case "$MODE" in
  commit)
    SCAN_DESC="staged changes"
    if scan_commit; then
      echo "[gitleaks] OK: no secrets found in $SCAN_DESC." >&2
      exit 0
    fi
    ;;
  push)
    SCAN_DESC="outgoing commits"
    if scan_push; then
      echo "[gitleaks] OK: no secrets found in $SCAN_DESC." >&2
      exit 0
    fi
    ;;
  *)
    echo "Usage: $0 [commit|push]" >&2
    exit 2
    ;;
esac

echo "[gitleaks] BLOCKED: potential secrets found in $SCAN_DESC." >&2
echo "Report: $REPORT_PATH" >&2
exit 1
