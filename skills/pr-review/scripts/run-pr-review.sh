#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-pr-review.sh <project_dir> [--output-file <path>] [--raw-log <path>] [--range <git-range>] [--timeout <seconds>]

Runs one parent Codex PR review over one frozen review packet. The parent is responsible for
spawning the fixed reviewer set in parallel and synthesizing the final result.

Examples:
  run-pr-review.sh .
  run-pr-review.sh . --range HEAD~3..HEAD
  run-pr-review.sh . --timeout 420 --raw-log /tmp/pr-review-raw.log
EOF
}

for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    usage
    exit 0
  fi
done

project_dir="${1:-$(pwd)}"
shift $(( $# >= 1 ? 1 : $# ))

output_file=""
raw_log=""
review_range=""
review_timeout_seconds="${PR_REVIEW_TIMEOUT_SECONDS:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --output-file requires a path" >&2; exit 2; }
      output_file="$2"
      shift 2
      ;;
    --raw-log)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --raw-log requires a path" >&2; exit 2; }
      raw_log="$2"
      shift 2
      ;;
    --range)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --range requires a git range" >&2; exit 2; }
      review_range="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --timeout requires seconds" >&2; exit 2; }
      review_timeout_seconds="$2"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$project_dir/.git" ]] && ! git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
  echo "error: project_dir is not a git repo: $project_dir" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "error: codex binary not found in PATH" >&2
  exit 2
fi

ensure_parent_dir() {
  local target_path="${1:-}"
  [[ -n "$target_path" ]] || return 0
  mkdir -p "$(dirname "$target_path")"
}

progress_snapshot() {
  local raw_path="$1"
  local required_count="$2"

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$raw_path" "$required_count" <<'PY'
import json
import sys

raw_path = sys.argv[1]
required_count = int(sys.argv[2])

reviewers = {}
statuses = {}
completed = set()

def normalize_prompt(prompt: str) -> str:
    prompt = (prompt or "").strip()
    prefix = "You are "
    if prompt.startswith(prefix):
        prompt = prompt[len(prefix):]
    for separator in (".", ":"):
        if separator in prompt:
            prompt = prompt.split(separator, 1)[0]
            break
    return prompt.strip() or "unknown-reviewer"

try:
    fh = open(raw_path, "r", encoding="utf-8")
except FileNotFoundError:
    print(f"0/{required_count}\t-")
    raise SystemExit(0)

with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        item = event.get("item") or {}
        event_type = event.get("type")
        item_type = item.get("type")
        tool_name = item.get("tool")

        if (
            event_type == "item.completed"
            and item_type == "collab_tool_call"
            and tool_name == "spawn_agent"
        ):
            name = normalize_prompt(item.get("prompt") or "")
            for receiver_id in item.get("receiver_thread_ids") or []:
                reviewers[receiver_id] = name
                state = ((item.get("agents_states") or {}).get(receiver_id) or {}).get("status")
                if state:
                    statuses[receiver_id] = state

        if (
            event_type == "item.completed"
            and item_type == "collab_tool_call"
            and tool_name in {"wait", "wait_agent"}
        ):
            for receiver_id, state in (item.get("agents_states") or {}).items():
                if receiver_id not in reviewers:
                    continue
                status = (state or {}).get("status")
                if status:
                    statuses[receiver_id] = status
                if status == "completed":
                    completed.add(receiver_id)

spawned_ids = list(reviewers.keys())
unresolved_parts = []
for receiver_id in spawned_ids:
    if receiver_id in completed:
        continue
    unresolved_parts.append(f"{reviewers[receiver_id]}({statuses.get(receiver_id, 'unknown')})")

unresolved = ", ".join(unresolved_parts) if unresolved_parts else "-"
print(f"{len(completed)}/{required_count}\t{unresolved}")
PY
}

append_guidance_file() {
  local label="$1"
  local candidate="$2"

  if [[ ! -f "$candidate" || -L "$candidate" ]]; then
    return 1
  fi
  if grep -Fxq "$candidate" "$seen_guidance_tmp"; then
    return 0
  fi

  printf '%s\n' "$candidate" >>"$seen_guidance_tmp"
  {
    printf '%s:\n' "$label"
    cat "$candidate"
    printf '\n\n'
  } >>"$guidance_tmp"
}

append_guidance_from_dir() {
  local dir="$1"
  local context="$2"
  local file candidate label

  for file in AGENTS.md CODEX.md CLAUDE.md; do
    candidate="$dir/$file"
    if [[ -n "$context" ]]; then
      label="$file for $context"
    else
      label="Root $file"
    fi
    append_guidance_file "$label" "$candidate" || true
  done
}

append_nearest_guidance_for_path() {
  local rel_path="$1"
  local dir found=0

  dir="$(dirname "$rel_path")"
  while [[ "$dir" != "." && "$dir" != "/" ]]; do
    local before_count after_count
    before_count="$(wc -l <"$seen_guidance_tmp" | tr -d ' ')"
    append_guidance_from_dir "$project_dir/$dir" "$dir"
    after_count="$(wc -l <"$seen_guidance_tmp" | tr -d ' ')"
    if [[ "$after_count" != "$before_count" ]]; then
      found=1
      break
    fi
    dir="$(dirname "$dir")"
  done
  return "$found"
}

build_untracked_diff() {
  local path diff_output diff_status had_output=0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ $had_output -eq 1 ]]; then
      printf '\n'
    fi

    diff_output=""
    if diff_output="$(git -C "$project_dir" diff --no-index --unified=0 -- /dev/null "$path" 2>&1)"; then
      diff_status=0
    else
      diff_status=$?
      if [[ $diff_status -ne 1 ]]; then
        echo "error: failed to build untracked diff for $path" >&2
        printf '%s\n' "$diff_output" >&2
        exit 2
      fi
    fi

    printf '%s' "$diff_output"
    had_output=1
  done < <(git -C "$project_dir" ls-files --others --exclude-standard)
}

default_branch=""
if default_branch_ref="$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
  default_branch="${default_branch_ref#refs/remotes/origin/}"
fi
if [[ -z "$default_branch" ]]; then
  default_branch="$(git -C "$project_dir" branch --format='%(refname:short)' | grep -E '^(main|master)$' | head -1 || true)"
fi

tmp_root="$(mktemp -d)"
changed_files_tmp="$tmp_root/changed-files.txt"
guidance_tmp="$tmp_root/guidance.md"
seen_guidance_tmp="$tmp_root/seen-guidance.txt"
packet_file="$tmp_root/review-packet.md"
prompt_file="$tmp_root/review.prompt"
raw_file="$tmp_root/review.raw"
out_file="$tmp_root/review.out"

cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

touch "$seen_guidance_tmp"
: >"$guidance_tmp"

scope_label=""
review_diff=""
repo_status="$(git -C "$project_dir" status --porcelain)"
branch_ahead_count="0"
if [[ -n "$default_branch" ]]; then
  branch_ahead_count="$(git -C "$project_dir" rev-list --count "${default_branch}..HEAD" 2>/dev/null || echo 0)"
fi

if [[ -n "$review_range" ]]; then
  scope_label="range:$review_range"
  git -C "$project_dir" diff --name-only --no-ext-diff "$review_range" | sed '/^$/d' >"$changed_files_tmp"
  review_diff="$(git -C "$project_dir" diff --unified=0 --no-ext-diff "$review_range")"
elif [[ -n "$repo_status" ]]; then
  scope_label="working-tree"
  {
    git -C "$project_dir" diff --name-only --cached --no-ext-diff
    git -C "$project_dir" diff --name-only --no-ext-diff
    git -C "$project_dir" ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u >"$changed_files_tmp"
  review_diff="$(
    {
      printf 'Staged diff:\n'
      git -C "$project_dir" diff --cached --unified=0 --no-ext-diff
      printf '\nUnstaged diff:\n'
      git -C "$project_dir" diff --unified=0 --no-ext-diff
      printf '\nUntracked file diffs:\n'
      build_untracked_diff
    }
  )"
elif [[ -n "$default_branch" && "$branch_ahead_count" != "0" ]]; then
  scope_label="branch:${default_branch}...HEAD"
  git -C "$project_dir" diff --name-only --no-ext-diff "${default_branch}...HEAD" | sed '/^$/d' >"$changed_files_tmp"
  review_diff="$(git -C "$project_dir" diff --unified=0 --no-ext-diff "${default_branch}...HEAD")"
else
  echo "error: nothing to review in $project_dir" >&2
  exit 2
fi

if [[ -z "$review_diff" ]]; then
  echo "error: review diff is empty for scope $scope_label" >&2
  exit 2
fi

typed_diff=false
typed_pattern='\.(ts|tsx|mts|cts|rs|go|java|kt|scala)$'
if command -v rg >/dev/null 2>&1; then
  if rg -q "$typed_pattern" "$changed_files_tmp"; then
    typed_diff=true
  fi
else
  if grep -Eq "$typed_pattern" "$changed_files_tmp"; then
    typed_diff=true
  fi
fi

append_guidance_from_dir "$project_dir" ""
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  append_nearest_guidance_for_path "$path" || true
done <"$changed_files_tmp"

if [[ ! -s "$guidance_tmp" ]]; then
  printf 'No project guidance files were found.\n' >"$guidance_tmp"
fi

{
  printf 'Review scope: %s\n' "$scope_label"
  printf 'Typed diff present: %s\n' "$typed_diff"
  printf 'Diff mode: compact unified=0\n\n'
  printf 'Changed files:\n'
  cat "$changed_files_tmp"
  printf '\nProject guidance:\n'
  cat "$guidance_tmp"
  printf '\nFrozen diff packet:\n```diff\n%s\n```\n' "$review_diff"
} >"$packet_file"

join_by() {
  local separator="$1"
  shift || true
  local first=1
  local item

  for item in "$@"; do
    if [[ $first -eq 1 ]]; then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$separator" "$item"
    fi
  done
}

reviewer_focus() {
  case "$1" in
    code-reviewer)
      printf '%s' 'General correctness, behavior regressions, edge cases, and maintainability issues.'
      ;;
    security-reviewer)
      printf '%s' 'Security vulnerabilities, auth and permission gaps, secrets handling, and trust-boundary mistakes.'
      ;;
    silent-failure-hunter)
      printf '%s' 'Swallowed errors, unsafe fallbacks, silent retries, and missing failure surfacing.'
      ;;
    pr-test-analyzer)
      printf '%s' 'Missing coverage for changed behavior, regression-catching tests, and important edge cases.'
      ;;
    comment-analyzer)
      printf '%s' 'Inaccurate comments, misleading docs, and explanation drift on changed lines.'
      ;;
    type-design-analyzer)
      printf '%s' 'Type safety, invariant expression, and interface design issues in typed-language diffs.'
      ;;
    *)
      printf '%s' 'General pull request review.'
      ;;
  esac
}

write_reviewer_prompt() {
  local reviewer="$1"
  local prompt_path="$2"
  local focus

  focus="$(reviewer_focus "$reviewer")"

  cat >"$prompt_path" <<EOF
You are $reviewer.

Specialty focus:
$focus

Review contract:
- Review only the frozen packet below.
- Do not run shell commands, read files, inspect the repo, inspect agent directories, inspect skill files, use MEMORY.md, or use tools.
- Only report issues on ADDED or MODIFIED lines.
- Return only findings with confidence >= 75.
- For each issue, include file path, line number, confidence, the concrete bug/risk, and a concise fix direction.
- If no qualifying issues exist, say exactly: No significant issues found.

Frozen review packet follows:

$(cat "$packet_file")
EOF
}

run_codex_prompt() {
  local prompt_path="$1"
  local out_path="$2"
  local raw_path="$3"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$review_timeout_seconds" \
      codex exec \
        --disable memories \
        --json \
        -o "$out_path" \
        -C "$project_dir" \
        <"$prompt_path" \
        >"$raw_path"
  else
    codex exec \
      --disable memories \
      --json \
      -o "$out_path" \
      -C "$project_dir" \
      <"$prompt_path" \
      >"$raw_path"
  fi
}

reviewers=(code-reviewer security-reviewer silent-failure-hunter pr-test-analyzer comment-analyzer)
if [[ "$typed_diff" == "true" ]]; then
  reviewers+=(type-design-analyzer)
fi
required_count="${#reviewers[@]}"

if [[ -n "$output_file" ]]; then
  ensure_parent_dir "$output_file"
else
  output_file="$(mktemp "${TMPDIR:-/tmp}/pr-review-report.XXXXXX")"
fi

if [[ -n "$raw_log" ]]; then
  ensure_parent_dir "$raw_log"
  : >"$raw_log"
  {
    printf 'wrapper.started\tscope=%s\n' "$scope_label"
    printf 'wrapper.reviewers\t%s\n' "$(join_by ',' "${reviewers[@]}")"
    printf 'wrapper.packet\t%s\n' "$packet_file"
    printf 'wrapper.report_path\t%s\n' "$output_file"
  } >>"$raw_log"
fi

reviewer_prompt_files=()
reviewer_raw_files=()
reviewer_out_files=()
reviewer_pids=()
reviewer_states=()
reviewer_exit_codes=()

for reviewer in "${reviewers[@]}"; do
  reviewer_prompt="$tmp_root/$reviewer.prompt"
  reviewer_raw="$tmp_root/$reviewer.raw"
  reviewer_out="$tmp_root/$reviewer.out"

  write_reviewer_prompt "$reviewer" "$reviewer_prompt"

  reviewer_prompt_files+=("$reviewer_prompt")
  reviewer_raw_files+=("$reviewer_raw")
  reviewer_out_files+=("$reviewer_out")
  reviewer_states+=("running")
  reviewer_exit_codes+=("")

  if [[ -n "$raw_log" ]]; then
    printf 'reviewer.started\tname=%s\traw=%s\toutput=%s\n' "$reviewer" "$reviewer_raw" "$reviewer_out" >>"$raw_log"
  fi

  (
    set +e
    run_codex_prompt "$reviewer_prompt" "$reviewer_out" "$reviewer_raw"
  ) &
  reviewer_pids+=("$!")
done

last_progress=""
last_progress_at=0
hard_failure=0

while :; do
  completed_count=0
  unresolved_parts=()
  active_count=0

  for i in "${!reviewers[@]}"; do
    state="${reviewer_states[$i]}"
    reviewer="${reviewers[$i]}"
    pid="${reviewer_pids[$i]}"
    reviewer_out="${reviewer_out_files[$i]}"
    reviewer_raw="${reviewer_raw_files[$i]}"

    case "$state" in
      success)
        completed_count=$((completed_count + 1))
        continue
        ;;
      failed:*)
        unresolved_parts+=("${reviewer}(${state#failed:})")
        continue
        ;;
    esac

    if kill -0 "$pid" >/dev/null 2>&1; then
      active_count=$((active_count + 1))
      unresolved_parts+=("${reviewer}(running)")
      continue
    fi

    if wait "$pid"; then
      exit_code=0
    else
      exit_code=$?
    fi
    reviewer_exit_codes[$i]="$exit_code"

    fail_reason=""
    if [[ "$exit_code" -ne 0 ]]; then
      fail_reason="exit=$exit_code"
    elif [[ ! -s "$reviewer_out" ]]; then
      fail_reason="empty-output"
    elif grep -Eq '(^REVIEW FAILED$|^Missing reviewers:|REVIEW FAILED[[:space:]]*$)' "$reviewer_out"; then
      fail_reason="invalid-output"
    fi

    if [[ -n "$fail_reason" ]]; then
      reviewer_states[$i]="failed:$fail_reason"
      unresolved_parts+=("${reviewer}($fail_reason)")
      hard_failure=1
      if [[ -n "$raw_log" ]]; then
        printf 'reviewer.failed\tname=%s\treason=%s\texit=%s\traw=%s\toutput=%s\n' \
          "$reviewer" "$fail_reason" "$exit_code" "$reviewer_raw" "$reviewer_out" >>"$raw_log"
      fi
    else
      reviewer_states[$i]="success"
      completed_count=$((completed_count + 1))
      if [[ -n "$raw_log" ]]; then
        printf 'reviewer.completed\tname=%s\texit=%s\traw=%s\toutput=%s\n' \
          "$reviewer" "$exit_code" "$reviewer_raw" "$reviewer_out" >>"$raw_log"
      fi
    fi
  done

  if [[ ${#unresolved_parts[@]} -eq 0 ]]; then
    unresolved='-'
  else
    unresolved="$(join_by ', ' "${unresolved_parts[@]}")"
  fi
  progress="${completed_count}/${required_count}"$'\t'"$unresolved"

  if [[ "$progress" != "$last_progress" ]]; then
    now_ts="$(date +%s)"
    if [[ "$last_progress_at" -eq 0 || $(( now_ts - last_progress_at )) -ge 2 ]]; then
      printf 'pr-review: progress %s\n' "$progress" >&2
      last_progress="$progress"
      last_progress_at="$now_ts"
    fi
  fi

  if [[ "$hard_failure" -eq 1 ]]; then
    for i in "${!reviewers[@]}"; do
      if [[ "${reviewer_states[$i]}" != "running" ]]; then
        continue
      fi

      pid="${reviewer_pids[$i]}"
      reviewer="${reviewers[$i]}"
      reviewer_raw="${reviewer_raw_files[$i]}"
      reviewer_out="${reviewer_out_files[$i]}"

      if kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
      fi
      wait "$pid" >/dev/null 2>&1 || true
      reviewer_states[$i]="failed:cancelled"

      if [[ -n "$raw_log" ]]; then
        printf 'reviewer.failed\tname=%s\treason=cancelled\texit=%s\traw=%s\toutput=%s\n' \
          "$reviewer" "${reviewer_exit_codes[$i]:-}" "$reviewer_raw" "$reviewer_out" >>"$raw_log"
      fi
    done
    break
  fi

  if [[ "$completed_count" -eq "$required_count" && "$active_count" -eq 0 ]]; then
    break
  fi

  sleep 2
done

missing_reviewers=()
for i in "${!reviewers[@]}"; do
  if [[ "${reviewer_states[$i]}" != "success" ]]; then
    missing_reviewers+=("${reviewers[$i]}")
  fi
done

if [[ ${#missing_reviewers[@]} -gt 0 ]]; then
  echo "error: pr-review reviewers did not complete cleanly" >&2
  echo "error: missing reviewers: $(join_by ', ' "${missing_reviewers[@]}")" >&2
  if [[ -n "$raw_log" ]]; then
    echo "error: raw log: $raw_log" >&2
  fi
  exit 3
fi

{
  cat <<EOF
Synthesize a PR review from the frozen packet and completed reviewer outputs below.

Rules:
- Do not use tools or spawn agents.
- Start with completion status: ${required_count} of ${required_count} agents completed
- Preserve findings-first output
- Use **Critical Issues** for confidence >= 91
- Use **Important Issues** for confidence 75-90
- Deduplicate overlapping findings across reviewers
- Only keep issues on ADDED or MODIFIED lines
- If nothing survives filtering, say exactly: No significant issues found.

Frozen review packet:

$(cat "$packet_file")

Reviewer outputs:

EOF

  for i in "${!reviewers[@]}"; do
    reviewer="${reviewers[$i]}"
    reviewer_out="${reviewer_out_files[$i]}"
    printf '## %s\n' "$reviewer"
    cat "$reviewer_out"
    printf '\n\n'
  done
} >"$prompt_file"

printf 'pr-review: synthesis started -> %s\n' "$output_file" >&2
if [[ -n "$raw_log" ]]; then
  printf 'synthesis.started\traw=%s\toutput=%s\treport=%s\n' "$raw_file" "$out_file" "$output_file" >>"$raw_log"
fi

codex_status=0
if ! run_codex_prompt "$prompt_file" "$out_file" "$raw_file"; then
  codex_status=$?
fi

if [[ -n "$raw_log" ]]; then
  printf 'synthesis.completed\texit=%s\traw=%s\toutput=%s\treport=%s\n' "$codex_status" "$raw_file" "$out_file" "$output_file" >>"$raw_log"
fi

if [[ "$codex_status" -eq 124 ]]; then
  echo "error: pr-review synthesis timed out after ${review_timeout_seconds}s" >&2
  tail -n 40 "$raw_file" >&2 || true
  exit 3
fi

if [[ "$codex_status" -ne 0 ]]; then
  echo "error: pr-review synthesis exited with status $codex_status" >&2
  tail -n 40 "$raw_file" >&2 || true
  exit 3
fi

if [[ ! -s "$out_file" ]]; then
  echo "error: pr-review synthesis output was empty" >&2
  tail -n 40 "$raw_file" >&2 || true
  exit 3
fi

if ! grep -Eq "^${required_count} of ${required_count} agents completed" "$out_file"; then
  echo "error: pr-review output did not include completion status" >&2
  cat "$out_file" >&2
  exit 3
fi

cp "$out_file" "$output_file"
printf 'pr-review: final report path %s\n' "$output_file" >&2
echo "$output_file"
