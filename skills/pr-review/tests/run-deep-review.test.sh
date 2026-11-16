#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/run-pr-review.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-wrapper-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_file_contains() {
  local path="$1"
  local pattern="$2"
  if ! grep -Eq "$pattern" "$path"; then
    echo "assertion failed: expected $path to contain pattern: $pattern" >&2
    echo "--- $path ---" >&2
    sed -n '1,220p' "$path" >&2 || true
    exit 1
  fi
}

assert_file_not_contains() {
  local path="$1"
  local pattern="$2"
  if grep -Eq "$pattern" "$path"; then
    echo "assertion failed: expected $path not to contain pattern: $pattern" >&2
    echo "--- $path ---" >&2
    sed -n '1,220p' "$path" >&2 || true
    exit 1
  fi
}

assert_line_order() {
  local path="$1"
  local first_pattern="$2"
  local second_pattern="$3"
  local first_line second_line

  first_line="$(grep -En "$first_pattern" "$path" | head -1 | cut -d: -f1 || true)"
  second_line="$(grep -En "$second_pattern" "$path" | head -1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    echo "assertion failed: expected '$first_pattern' before '$second_pattern' in $path" >&2
    echo "--- $path ---" >&2
    cat "$path" >&2
    exit 1
  fi
}

make_fake_codex() {
  local fakebin="$1"
  mkdir -p "$fakebin"
  cat >"$fakebin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out_path=""
if [[ -n "${FAKE_CODEX_ARG_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_CODEX_ARG_LOG"
fi
if [[ -n "${FAKE_CODEX_STDERR:-}" ]]; then
  printf '%s\n' "$FAKE_CODEX_STDERR" >&2
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out_path="$2"
      shift 2
      ;;
    -C)
      shift 2
      ;;
    --enable|--disable)
      if [[ "$2" != "memories" ]]; then
        echo "Error: Unknown feature flag: $2" >&2
        exit 2
      fi
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
printf '{"type":"fake"}\n'

if [[ -z "$out_path" ]]; then
  echo "fake codex missing -o" >&2
  exit 2
fi

if [[ -n "${FAKE_CODEX_FAIL_REVIEWER:-}" ]] && grep -q "You are ${FAKE_CODEX_FAIL_REVIEWER}." <<<"$prompt"; then
  exit 124
fi

if grep -q "Synthesize " <<<"$prompt"; then
  count="$(grep -Eo 'Start the report with this exact line: [0-9]+ of [0-9]+ agents completed' <<<"$prompt" | grep -Eo '^[^0-9]*[0-9]+ of [0-9]+ agents completed' | sed 's/^[^0-9]*//' | head -1)"
  if [[ -z "$count" ]]; then
    count="1 of 1 agents completed"
  fi
  {
    printf '%s\n\n' "$count"
    printf 'No significant issues found.\n'
  } >"$out_path"
else
  {
    printf 'Review evidence:\n'
    printf -- '- fake reviewer inspected the supplied prompt\n\n'
    printf 'Findings:\n'
    printf 'No significant issues found.\n'
  } >"$out_path"
fi
EOF
  chmod +x "$fakebin/codex"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo/src"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"
  git -C "$repo" config commit.gpgsign false
  cat >"$repo/src/app.ts" <<'EOF'
export function parseLimit(input: string): number {
  return Number(input);
}
EOF
  git -C "$repo" add src/app.ts
  git -C "$repo" commit -q -m "initial"
  cat >"$repo/src/app.ts" <<'EOF'
export function parseLimit(input: string): number {
  const parsed = Number(input);
  return Number.isFinite(parsed) ? parsed : 0;
}
EOF
}

fakebin="$TMP_ROOT/fakebin"
make_fake_codex "$fakebin"

repo="$TMP_ROOT/repo"
make_repo "$repo"
context_file="$TMP_ROOT/context.md"
cat >"$context_file" <<'EOF'
The change should reject invalid limits without silently accepting malformed input.
EOF

report="$TMP_ROOT/report.md"
raw_log="$TMP_ROOT/raw.log"
codex_arg_log="$TMP_ROOT/codex-args.log"
FAKE_CODEX_ARG_LOG="$codex_arg_log" \
FAKE_CODEX_STDERR="fake codex stderr" \
PATH="$fakebin:$PATH" "$WRAPPER" "$repo" \
  --deep \
  --uncommitted \
  --output-file "$report" \
  --raw-log "$raw_log" \
  --acceptance-context "$context_file" \
  --cleanup-tmp >/dev/null 2>"$TMP_ROOT/run.stderr"

artifacts="$report.artifacts"
assert_file_contains "$report" '^7 of 7 agents completed$'
assert_file_contains "$raw_log" '^wrapper\.mode[[:space:]]+thorough$'
assert_file_contains "$raw_log" '^wrapper\.candidate_threshold[[:space:]]+60$'
assert_file_contains "$raw_log" '^wrapper\.base_timeout_seconds[[:space:]]+300$'
assert_file_contains "$raw_log" '^wrapper\.security_timeout_seconds[[:space:]]+600$'
assert_file_contains "$raw_log" '^wrapper\.silent_failure_timeout_seconds[[:space:]]+600$'
assert_file_contains "$raw_log" '^wrapper\.first_wave_tasks[[:space:]]+6$'
assert_file_contains "$raw_log" '^wrapper\.simplifier_tasks[[:space:]]+1$'
assert_file_contains "$raw_log" 'reviewer\.started.*name=code-reviewer-shard-1.*timeout=300'
assert_file_contains "$raw_log" 'reviewer\.started.*name=security-reviewer-shard-1.*timeout=600'
assert_file_contains "$raw_log" 'reviewer\.started.*name=silent-failure-hunter-shard-1.*timeout=600'
assert_file_contains "$raw_log" 'reviewer\.phase_progress.*phase=first-wave.*progress=6/6'
assert_file_contains "$raw_log" 'reviewer\.phase_progress.*phase=code-simplifier.*progress=1/1'
assert_line_order "$raw_log" 'reviewer\.first_wave_outputs_preserved' 'reviewer\.started.*code-simplifier-shard-1'
assert_file_contains "$raw_log" 'reviewer\.completed.*duration='
assert_file_contains "$raw_log" 'reviewer\.completed.*stderr='
assert_file_contains "$raw_log" 'synthesis\.completed.*duration='
assert_file_contains "$raw_log" 'synthesis\.completed.*stderr='
assert_file_contains "$codex_arg_log" 'exec --sandbox read-only -c approval_policy="never" --disable memories'
assert_file_not_contains "$TMP_ROOT/run.stderr" 'fake codex stderr'
assert_file_not_contains "$TMP_ROOT/run.stderr" 'ripgrep requires at least one pattern'
assert_file_contains "$artifacts/code-reviewer-shard-1.prompt.md" 'You may use read-only tools or shell commands'
assert_file_contains "$artifacts/code-reviewer-shard-1.prompt.md" 'Keep read-only context bounded'
assert_file_contains "$artifacts/code-reviewer-shard-1.prompt.md" 'Runtime-required skill instructions still apply'
assert_file_contains "$artifacts/code-reviewer-shard-1.prompt.md" 'Return candidate findings with confidence >= 60 and < 75'
assert_file_contains "$artifacts/code-reviewer-shard-1.prompt.md" 'The change should reject invalid limits'
assert_file_contains "$artifacts/code-reviewer-shard-1.stderr.log" 'fake codex stderr'
assert_file_contains "$artifacts/code-simplifier-shard-1.prompt.md" 'First-wave reviewer outputs for simplifier context'
assert_file_contains "$artifacts/first-wave-reviewer-outputs.md" '^# First-Wave Reviewer Outputs$'
assert_file_contains "$artifacts/synthesis.prompt.md" 'High-Confidence Findings'
assert_file_contains "$artifacts/synthesis.stderr.log" 'fake codex stderr'

fast_report="$TMP_ROOT/fast-report.md"
fast_raw_log="$TMP_ROOT/fast-raw.log"
PATH="$fakebin:$PATH" "$WRAPPER" "$repo" \
  --deep \
  --output-file "$fast_report" \
  --raw-log "$fast_raw_log" \
  --fast \
  --cleanup-tmp >/dev/null 2>"$TMP_ROOT/fast.stderr"

fast_artifacts="$fast_report.artifacts"
assert_file_contains "$fast_report" '^7 of 7 agents completed$'
assert_file_contains "$fast_raw_log" '^wrapper\.mode[[:space:]]+fast$'
assert_file_contains "$fast_raw_log" '^wrapper\.candidate_threshold[[:space:]]+75$'
assert_file_contains "$fast_raw_log" '^wrapper\.security_timeout_seconds[[:space:]]+300$'
assert_file_contains "$fast_raw_log" '^wrapper\.silent_failure_timeout_seconds[[:space:]]+300$'
assert_file_contains "$fast_raw_log" '^wrapper\.first_wave_tasks[[:space:]]+6$'
assert_file_contains "$fast_raw_log" '^wrapper\.simplifier_tasks[[:space:]]+1$'
assert_file_contains "$fast_raw_log" 'reviewer\.phase_progress.*phase=first-wave.*progress=6/6'
assert_file_contains "$fast_raw_log" 'reviewer\.phase_progress.*phase=code-simplifier.*progress=1/1'
assert_file_contains "$fast_artifacts/code-reviewer-shard-1.prompt.md" 'Analyze the supplied packet without repository tools'
assert_file_contains "$fast_artifacts/code-reviewer-shard-1.prompt.md" 'Return only findings with confidence >= 75'

fail_report="$TMP_ROOT/fail-report.md"
fail_raw_log="$TMP_ROOT/fail-raw.log"
set +e
FAKE_CODEX_FAIL_REVIEWER=silent-failure-hunter PATH="$fakebin:$PATH" "$WRAPPER" "$repo" \
  --deep \
  --output-file "$fail_report" \
  --raw-log "$fail_raw_log" \
  --cleanup-tmp >/dev/null 2>"$TMP_ROOT/fail.stderr"
fail_status=$?
set -e

if [[ "$fail_status" -eq 0 ]]; then
  echo "assertion failed: expected simulated reviewer failure" >&2
  exit 1
fi

fail_artifacts="$fail_report.artifacts"
assert_file_contains "$fail_raw_log" 'reviewer\.phase_progress.*phase=first-wave.*progress=5/6'
assert_file_contains "$fail_raw_log" 'reviewer\.failed.*name=silent-failure-hunter-shard-1.*reason=exit=124.*duration='
assert_file_not_contains "$fail_raw_log" 'reviewer\.started.*code-simplifier-shard-1'
assert_file_not_contains "$fail_raw_log" 'synthesis\.started'
assert_file_contains "$fail_report" '^# FAILED REVIEW - PARTIAL OUTPUTS$'
assert_file_contains "$fail_report" 'Review failed before synthesis'
assert_file_contains "$fail_report" 'Failed reviewers: silent-failure-hunter-shard-1\(exit=124\)'
assert_file_contains "$fail_artifacts/partial-review-report.md" '^# FAILED REVIEW - PARTIAL OUTPUTS$'
assert_file_contains "$TMP_ROOT/fail.stderr" 'partial failure report:'

if command -v script >/dev/null 2>&1 && script -q /dev/null true >/dev/null 2>&1; then
  pty_report="$TMP_ROOT/pty-report.md"
  pty_raw_log="$TMP_ROOT/pty-raw.log"
  python3 - "$fakebin" "$WRAPPER" "$repo" "$pty_report" "$pty_raw_log" \
    >/dev/null 2>"$TMP_ROOT/pty.stderr" <<'PY'
import os
import subprocess
import sys

fakebin, wrapper, repo, report, raw_log = sys.argv[1:]
subprocess.run(
    ["script", "-q", "/dev/null", "env", f"PATH={fakebin}:{os.environ['PATH']}",
     wrapper, repo, "--deep", "--output-file", report, "--raw-log", raw_log,
     "--mode", "thorough", "--cleanup-tmp"],
    check=True, timeout=30,
)
PY
  assert_file_contains "$pty_report" '^7 of 7 agents completed$'
  assert_file_contains "$pty_raw_log" 'reviewer\.phase_progress.*phase=first-wave.*progress=6/6'
fi

# Exercise native-style scope flags through the deep dispatcher as well.
git -C "$repo" add src/app.ts
git -C "$repo" commit -q -m "change"
for scope_flag in --base --commit; do
  scope_ref=HEAD
  [[ "$scope_flag" != --base ]] || scope_ref=HEAD~1
  scope_report="$TMP_ROOT/scope-${scope_flag#--}.md"
  PATH="$fakebin:$PATH" "$WRAPPER" "$repo" --deep "$scope_flag" "$scope_ref" \
    --fast --output-file "$scope_report" --cleanup-tmp >/dev/null 2>"$TMP_ROOT/scope.stderr"
  assert_file_contains "$scope_report" '^7 of 7 agents completed$'
done

echo "deep review wrapper tests passed"
