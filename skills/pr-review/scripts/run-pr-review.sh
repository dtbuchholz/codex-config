#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: run-pr-review.sh <project_dir> [--output-file <path>] [--raw-log <path>] [--range <git-range>] [--timeout <seconds>] [--context-lines <n>] [--path <pathspec>] [--max-packet-bytes <n>] [--include-lockfiles] [--keep-tmp|--cleanup-tmp]

Runs one parent Codex PR review over one frozen review packet. The parent is responsible for
spawning the fixed reviewer set in parallel and synthesizing the final result.

Examples:
  run-pr-review.sh .
  run-pr-review.sh . --range HEAD~3..HEAD
  run-pr-review.sh . --timeout 420 --raw-log /tmp/pr-review-raw.log
  run-pr-review.sh . --context-lines 80
  run-pr-review.sh . --path executors/polymarket-sum-to-one/src
  run-pr-review.sh . --include-lockfiles
  run-pr-review.sh . --keep-tmp
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
review_context_lines="${PR_REVIEW_CONTEXT_LINES:-40}"
max_packet_bytes="${PR_REVIEW_MAX_PACKET_BYTES:-850000}"
keep_tmp="${PR_REVIEW_KEEP_TMP:-1}"
include_lockfiles="${PR_REVIEW_INCLUDE_LOCKFILES:-0}"
path_filters=()

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
    --context-lines)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --context-lines requires a number" >&2; exit 2; }
      review_context_lines="$2"
      shift 2
      ;;
    --path)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --path requires a pathspec" >&2; exit 2; }
      path_filters+=("$2")
      shift 2
      ;;
    --max-packet-bytes)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: --max-packet-bytes requires a number" >&2; exit 2; }
      max_packet_bytes="$2"
      shift 2
      ;;
    --include-lockfiles)
      include_lockfiles=1
      shift
      ;;
    --keep-tmp)
      keep_tmp=1
      shift
      ;;
    --cleanup-tmp)
      keep_tmp=0
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$review_context_lines" =~ ^[0-9]+$ ]]; then
  echo "error: --context-lines must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$max_packet_bytes" =~ ^[0-9]+$ ]] || [[ "$max_packet_bytes" -lt 100000 ]]; then
  echo "error: --max-packet-bytes must be an integer >= 100000" >&2
  exit 2
fi
if [[ "$keep_tmp" != "0" && "$keep_tmp" != "1" ]]; then
  echo "error: PR_REVIEW_KEEP_TMP must be 0 or 1" >&2
  exit 2
fi
if [[ "$include_lockfiles" != "0" && "$include_lockfiles" != "1" ]]; then
  echo "error: PR_REVIEW_INCLUDE_LOCKFILES must be 0 or 1" >&2
  exit 2
fi

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

git_diff_name_only() {
  if [[ ${#path_filters[@]} -gt 0 ]]; then
    git -C "$project_dir" diff --name-only --no-ext-diff "$@" -- "${path_filters[@]}"
  else
    git -C "$project_dir" diff --name-only --no-ext-diff "$@"
  fi
}

git_ls_untracked() {
  if [[ ${#path_filters[@]} -gt 0 ]]; then
    git -C "$project_dir" ls-files --others --exclude-standard -- "${path_filters[@]}"
  else
    git -C "$project_dir" ls-files --others --exclude-standard
  fi
}

path_is_untracked() {
  local path="$1"
  grep -Fxq "$path" "$untracked_files_tmp"
}

excluded_file_reason() {
  local path="$1"
  local base="${path##*/}"

  if [[ "$include_lockfiles" == "1" ]]; then
    return 1
  fi

  case "$base" in
    pnpm-lock.yaml|package-lock.json|npm-shrinkwrap.json|yarn.lock|bun.lock|bun.lockb)
      printf '%s' 'javascript-lockfile'
      return 0
      ;;
    Cargo.lock|Gemfile.lock|Pipfile.lock|poetry.lock|uv.lock|pdm.lock|composer.lock|go.sum)
      printf '%s' 'dependency-lockfile'
      return 0
      ;;
    gradle.lockfile|pubspec.lock|Podfile.lock|Package.resolved|packages.lock.json|flake.lock)
      printf '%s' 'dependency-lockfile'
      return 0
      ;;
    *.lock)
      printf '%s' 'lockfile'
      return 0
      ;;
  esac

  return 1
}

filter_packet_files() {
  local input_path="$1"
  local output_path="$2"
  local excluded_path="$3"
  local path reason

  : >"$output_path"
  : >"$excluded_path"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if reason="$(excluded_file_reason "$path")"; then
      printf '%s\t%s\n' "$reason" "$path" >>"$excluded_path"
    else
      printf '%s\n' "$path" >>"$output_path"
    fi
  done <"$input_path"
}

build_untracked_diff() {
  local path diff_output diff_status had_output=0

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ $had_output -eq 1 ]]; then
      printf '\n'
    fi

    diff_output=""
    if diff_output="$(git -C "$project_dir" diff --no-index "--unified=$review_context_lines" -- /dev/null "$path" 2>&1)"; then
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
  done <"$untracked_files_tmp"
}

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

default_branch=""
if default_branch_ref="$(git -C "$project_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
  default_branch="${default_branch_ref#refs/remotes/origin/}"
fi
if [[ -z "$default_branch" ]]; then
  default_branch="$(git -C "$project_dir" branch --format='%(refname:short)' | grep -E '^(main|master)$' | head -1 || true)"
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/pr-review-work.XXXXXX")"
all_changed_files_tmp="$tmp_root/all-changed-files.txt"
changed_files_tmp="$tmp_root/changed-files.txt"
untracked_files_tmp="$tmp_root/untracked-files.txt"
all_untracked_files_tmp="$tmp_root/all-untracked-files.txt"
excluded_files_tmp="$tmp_root/excluded-files.txt"
guidance_tmp="$tmp_root/guidance.md"
seen_guidance_tmp="$tmp_root/seen-guidance.txt"
snippet_dir="$tmp_root/snippets"
packet_dir="$tmp_root/packets"
prompt_file="$tmp_root/review.prompt"
raw_file="$tmp_root/review.raw"
out_file="$tmp_root/review.out"
mkdir -p "$snippet_dir" "$packet_dir"

cleanup() {
  if [[ "$keep_tmp" == "0" ]]; then
    rm -rf "$tmp_root"
  fi
}
trap cleanup EXIT

if [[ "$keep_tmp" == "1" ]]; then
  printf 'pr-review: workdir %s\n' "$tmp_root" >&2
fi

touch "$seen_guidance_tmp"
: >"$guidance_tmp"

scope_label=""
scope_kind=""
repo_status="$(git -C "$project_dir" status --porcelain)"
branch_ahead_count="0"
if [[ -n "$default_branch" ]]; then
  branch_ahead_count="$(git -C "$project_dir" rev-list --count "${default_branch}..HEAD" 2>/dev/null || echo 0)"
fi

if [[ -n "$review_range" ]]; then
  scope_label="range:$review_range"
  scope_kind="range"
  : >"$untracked_files_tmp"
  : >"$all_untracked_files_tmp"
  git_diff_name_only "$review_range" | sed '/^$/d' >"$all_changed_files_tmp"
elif [[ -n "$repo_status" ]]; then
  scope_label="working-tree"
  scope_kind="working-tree"
  git_ls_untracked | sed '/^$/d' | sort -u >"$all_untracked_files_tmp"
  filter_packet_files "$all_untracked_files_tmp" "$untracked_files_tmp" "$tmp_root/excluded-untracked-files.txt"
  {
    git_diff_name_only --cached
    git_diff_name_only
    cat "$all_untracked_files_tmp"
  } | sed '/^$/d' | sort -u >"$all_changed_files_tmp"
elif [[ -n "$default_branch" && "$branch_ahead_count" != "0" ]]; then
  scope_label="branch:${default_branch}...HEAD"
  scope_kind="branch"
  : >"$untracked_files_tmp"
  : >"$all_untracked_files_tmp"
  git_diff_name_only "${default_branch}...HEAD" | sed '/^$/d' >"$all_changed_files_tmp"
else
  echo "error: nothing to review in $project_dir" >&2
  exit 2
fi

filter_packet_files "$all_changed_files_tmp" "$changed_files_tmp" "$excluded_files_tmp"

if [[ ! -s "$changed_files_tmp" ]]; then
  if [[ -s "$excluded_files_tmp" ]]; then
    echo "error: all changed files were excluded from the review packet by default" >&2
    echo "error: excluded files:" >&2
    awk -F '\t' '{ printf "  %s\t%s\n", $1, $2 }' "$excluded_files_tmp" >&2
    echo "error: retry with --include-lockfiles if these dependency artifacts are the intended review target" >&2
  elif [[ ${#path_filters[@]} -gt 0 ]]; then
    echo "error: no changed files matched path filter(s): $(join_by ', ' "${path_filters[@]}")" >&2
  else
    echo "error: no changed files found for scope $scope_label" >&2
  fi
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

write_file_diff_snippet() {
  local path="$1"
  local snippet_path="$2"
  local body_path="$snippet_path.body"
  local diff_output diff_status

  : >"$body_path"

  case "$scope_kind" in
    range)
      git -C "$project_dir" diff "--unified=$review_context_lines" --no-ext-diff "$review_range" -- "$path" >"$body_path"
      ;;
    branch)
      git -C "$project_dir" diff "--unified=$review_context_lines" --no-ext-diff "${default_branch}...HEAD" -- "$path" >"$body_path"
      ;;
    working-tree)
      git -C "$project_dir" diff --cached "--unified=$review_context_lines" --no-ext-diff -- "$path" >>"$body_path"
      git -C "$project_dir" diff "--unified=$review_context_lines" --no-ext-diff -- "$path" >>"$body_path"
      if path_is_untracked "$path"; then
        diff_output=""
        if diff_output="$(cd "$project_dir" && git diff --no-index "--unified=$review_context_lines" -- /dev/null "$path" 2>&1)"; then
          diff_status=0
        else
          diff_status=$?
          if [[ $diff_status -ne 1 ]]; then
            echo "error: failed to build untracked diff for $path" >&2
            printf '%s\n' "$diff_output" >&2
            exit 2
          fi
        fi
        [[ ! -s "$body_path" ]] || printf '\n' >>"$body_path"
        printf '%s\n' "$diff_output" >>"$body_path"
      fi
      ;;
    *)
      echo "error: internal unknown scope kind: $scope_kind" >&2
      exit 2
      ;;
  esac

  if [[ -s "$body_path" ]]; then
    {
      printf '### File: %s\n\n' "$path"
      cat "$body_path"
      printf '\n'
    } >"$snippet_path"
  else
    : >"$snippet_path"
  fi
  rm -f "$body_path"
}

packet_size_bytes() {
  wc -c <"$1" | tr -d ' '
}

top_packet_contributors() {
  sort -nr "$snippet_sizes_tmp" | head -10 | awk -F '\t' '{ printf "  %s bytes\t%s\n", $1, $2 }'
}

snippet_path_for_file() {
  local target_path="$1"
  local i

  for i in "${!snippet_files[@]}"; do
    if [[ "${snippet_files[$i]}" == "$target_path" ]]; then
      printf '%s' "${snippet_paths[$i]}"
      return 0
    fi
  done

  echo "error: internal missing diff snippet for $target_path" >&2
  exit 2
}

write_packet() {
  local packet_path="$1"
  local shard_number="$2"
  local shard_total="$3"
  shift 3
  local path snippet_path

  {
    printf 'Review scope: %s\n' "$scope_label"
    printf 'Shard: %s of %s\n' "$shard_number" "$shard_total"
    printf 'Typed diff present: %s\n' "$typed_diff"
    printf 'Diff mode: unified=%s\n' "$review_context_lines"
    printf 'Max packet bytes: %s\n' "$max_packet_bytes"
    printf 'Include lockfiles: %s\n' "$include_lockfiles"
    if [[ ${#path_filters[@]} -gt 0 ]]; then
      printf 'Path filters: %s\n' "$(join_by ', ' "${path_filters[@]}")"
    fi
    printf '\nChanged files in this shard:\n'
    for path in "$@"; do
      printf '%s\n' "$path"
    done
    printf '\nAll changed files included in reviewer packets:\n'
    cat "$changed_files_tmp"
    if [[ -s "$excluded_files_tmp" ]]; then
      printf '\nFiles excluded from reviewer packet:\n'
      awk -F '\t' '{ printf "%s\t%s\n", $1, $2 }' "$excluded_files_tmp"
    fi
    printf '\nProject guidance:\n'
    cat "$guidance_tmp"
    printf '\nFrozen diff packet shard:\n```diff\n'
    for path in "$@"; do
      snippet_path="$(snippet_path_for_file "$path")"
      cat "$snippet_path"
      printf '\n'
    done
    printf '```\n'
  } >"$packet_path"
}

snippet_sizes_tmp="$tmp_root/snippet-sizes.tsv"
: >"$snippet_sizes_tmp"
snippet_files=()
snippet_paths=()

file_index=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  file_index=$((file_index + 1))
  snippet_path="$snippet_dir/file-$file_index.diff.md"
  write_file_diff_snippet "$path" "$snippet_path"
  if [[ ! -s "$snippet_path" ]]; then
    continue
  fi
  snippet_size="$(packet_size_bytes "$snippet_path")"
  snippet_files+=("$path")
  snippet_paths+=("$snippet_path")
  printf '%s\t%s\n' "$snippet_size" "$path" >>"$snippet_sizes_tmp"
done <"$changed_files_tmp"

if [[ ${#snippet_files[@]} -eq 0 ]]; then
  echo "error: no diff content found for scope $scope_label" >&2
  exit 2
fi

packet_files=()
packet_file_lists=()
current_files=()
packet_index=0
candidate_packet="$tmp_root/candidate-packet.md"

finalize_packet() {
  [[ ${#current_files[@]} -gt 0 ]] || return 0
  packet_index=$((packet_index + 1))
  local packet_path="$packet_dir/review-packet-$packet_index.md"
  write_packet "$packet_path" "$packet_index" "TBD" "${current_files[@]}"
  packet_files+=("$packet_path")
  packet_file_lists+=("$(join_by $'\n' "${current_files[@]}")")
  current_files=()
}

for path in "${snippet_files[@]}"; do
  candidate_files=("${current_files[@]}" "$path")
  write_packet "$candidate_packet" "$((packet_index + 1))" "TBD" "${candidate_files[@]}"
  candidate_size="$(packet_size_bytes "$candidate_packet")"

  if [[ "$candidate_size" -le "$max_packet_bytes" ]]; then
    current_files=("${candidate_files[@]}")
    continue
  fi

  if [[ ${#current_files[@]} -eq 0 ]]; then
    echo "error: frozen packet for a single file exceeds --max-packet-bytes" >&2
    echo "error: file: $path" >&2
    echo "error: packet bytes: $candidate_size" >&2
    echo "error: max packet bytes: $max_packet_bytes" >&2
    echo "error: top diff contributors:" >&2
    top_packet_contributors >&2
    echo "error: retry with --path, a narrower --range, or by excluding/generated large files from the review scope" >&2
    exit 2
  fi

  finalize_packet
  current_files=("$path")
  write_packet "$candidate_packet" "$((packet_index + 1))" "TBD" "${current_files[@]}"
  candidate_size="$(packet_size_bytes "$candidate_packet")"
  if [[ "$candidate_size" -gt "$max_packet_bytes" ]]; then
    echo "error: frozen packet for a single file exceeds --max-packet-bytes" >&2
    echo "error: file: $path" >&2
    echo "error: packet bytes: $candidate_size" >&2
    echo "error: max packet bytes: $max_packet_bytes" >&2
    echo "error: top diff contributors:" >&2
    top_packet_contributors >&2
    echo "error: retry with --path, a narrower --range, or by excluding/generated large files from the review scope" >&2
    exit 2
  fi
done
finalize_packet

packet_count="${#packet_files[@]}"
for i in "${!packet_files[@]}"; do
  shard_number=$((i + 1))
  packet_path="${packet_files[$i]}"
  shard_files=()
  while IFS= read -r shard_file; do
    [[ -n "$shard_file" ]] || continue
    shard_files+=("$shard_file")
  done <<<"${packet_file_lists[$i]}"
  write_packet "$packet_path" "$shard_number" "$packet_count" "${shard_files[@]}"
  packet_size="$(packet_size_bytes "$packet_path")"
  if [[ "$packet_size" -gt "$max_packet_bytes" ]]; then
    echo "error: internal packet sharding produced an oversized packet" >&2
    echo "error: packet: $packet_path" >&2
    echo "error: packet bytes: $packet_size" >&2
    echo "error: max packet bytes: $max_packet_bytes" >&2
    exit 2
  fi
done
rm -f "$candidate_packet"

reviewer_focus() {
  case "$1" in
    code-reviewer)
      printf '%s' 'General correctness, behavior regressions, semantic contract mismatches, edge cases, and maintainability issues.'
      ;;
    security-reviewer)
      printf '%s' 'Security vulnerabilities, auth and permission gaps, secrets handling, and trust-boundary mistakes.'
      ;;
    silent-failure-hunter)
      printf '%s' 'Swallowed errors, unsafe fallbacks, silent retries, missing failure surfacing, and misleading control-plane semantics.'
      ;;
    pr-test-analyzer)
      printf '%s' 'Missing coverage for changed behavior, new helper/module seams, regression-catching tests, and important edge cases.'
      ;;
    comment-analyzer)
      printf '%s' 'Inaccurate comments, misleading docs, and explanation drift on changed lines.'
      ;;
    code-simplifier)
      printf '%s' 'Avoidable duplication, overcomplicated parsing/control flow, unnecessary abstractions, and clear simplification opportunities tied to changed behavior.'
      ;;
    type-design-analyzer)
      printf '%s' 'Type safety, invariant expression, interface design, over-broad shapes, and typo-prone local contracts in typed-language diffs.'
      ;;
    *)
      printf '%s' 'General pull request review.'
      ;;
  esac
}

reviewer_checklist() {
  case "$1" in
    code-reviewer)
      cat <<'EOF'
- Check whether new call sites preserve the semantic contract implied by function names, TSDoc, comments, and nearby usage in the packet.
- Report naming/control-plane mismatches when they can cause future callers to use a helper for the wrong scope or lifecycle, even if the current runtime path still works.
- Check adapter/layering changes for duplicated wrapping, lossy projection, and payload-shape drift at boundaries.
EOF
      ;;
    security-reviewer)
      cat <<'EOF'
- Check whether broadened payloads, details maps, logging, or status/event emissions can leak sensitive or unexpectedly large data.
- Check trust-boundary changes, especially when a new generic object shape crosses from internal logic into logs, status APIs, or external sinks.
EOF
      ;;
    silent-failure-hunter)
      cat <<'EOF'
- Check whether new helper names, cooldown/limiter semantics, fallbacks, or status payloads make failures look scoped differently than they really are.
- Report mismatches between documented lifecycle/scope and the changed call path when they can hide skipped work, suppressed attempts, or misclassified no-op behavior.
EOF
      ;;
    pr-test-analyzer)
      cat <<'EOF'
- Check whether every newly extracted non-trivial helper/module has direct unit coverage for its local edge cases.
- Do not treat broad integration tests as sufficient when a new module centralizes parsing, projection, logging, filtering, rate limiting, or state tracking logic.
- Missing-test findings are valid when tied to a new changed file/module or changed behavior, even if there is no added test-file line to cite.
EOF
      ;;
    comment-analyzer)
      cat <<'EOF'
- Check TSDoc, comments, README text, env examples, and names against the changed implementation behavior.
- Report stale or misleading documentation when the diff changes the scope, lifecycle, payload shape, or semantics that the text describes.
EOF
      ;;
    code-simplifier)
      cat <<'EOF'
- Check for unnecessary adapter layering, double wrapping/unwrapping, repeated projection logic, and broad generic shapes where a smaller local type would simplify the changed behavior.
- Report simplifications when they reduce bug surface at a changed boundary, even if the existing behavior is not yet broken.
EOF
      ;;
    type-design-analyzer)
      cat <<'EOF'
- Check for new or widened `string`, `Record<string, unknown>`, `Partial<T>`, optional bags, and weak unions on local contracts.
- Report type-design findings when a bounded local union, exact object shape, or stricter constructor/config type would prevent typo-prone reasons/phases, invalid partial controls, or payload leaks in changed behavior.
- Do not require a pre-existing canonical catalog to report a local closed set if the diff itself shows the practical allowed values.
EOF
      ;;
    *)
      cat <<'EOF'
- Check the changed hunks for specialty-specific defects, test gaps, and maintainability risks tied to changed behavior.
EOF
      ;;
  esac
}

write_reviewer_prompt() {
  local reviewer="$1"
  local prompt_path="$2"
  local packet_path="$3"
  local shard_label="$4"
  local focus checklist

  focus="$(reviewer_focus "$reviewer")"
  checklist="$(reviewer_checklist "$reviewer")"

  cat >"$prompt_path" <<EOF
You are $reviewer.

Specialty focus:
$focus

Specialty checklist:
$checklist

Review contract:
- Review only the frozen packet shard below.
- This is shard $shard_label of the frozen review scope; do not infer findings from files absent from this shard.
- Do not run shell commands, read files, inspect the repo, inspect agent directories, inspect skill files, use MEMORY.md, or use tools.
- Inspect the actual diff hunks, not just the file list, guidance text, or high-level summary.
- Before returning no findings, make a concrete pass over each changed file in this shard and verify your specialty focus against the changed lines.
- Report only issues tied to changed behavior in this diff.
- For code defects, cite the ADDED or MODIFIED line that introduced the risk.
- For missing-test findings, cite the changed behavior or changed file that needs coverage; absence of a test does not need a test-file line.
- Type-design, simplification, naming, and semantic-contract findings are in scope when they materially affect the changed behavior, changed API surface, or future safety of a changed helper/module.
- Do not suppress a confidence >= 75 type-design or test-gap finding merely because it is not an immediate runtime crash.
- Return only findings with confidence >= 75.
- For each issue, include file path, line number, confidence, the concrete bug/risk, and a concise fix direction.
- Always include a "Review evidence:" section with concise bullets naming the files or diff areas you inspected for your specialty.
- Then include a "Findings:" section.
- If no qualifying issues exist, put exactly "No significant issues found." under "Findings:".

Frozen review packet follows:

$(cat "$packet_path")
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

reviewer_output_has_evidence() {
  local out_path="$1"
  local evidence_heading='^[[:space:]]*(#{1,6}[[:space:]]*)?(\*\*)?Review evidence:?(\*\*)?[[:space:]]*$'
  local findings_heading='^[[:space:]]*(#{1,6}[[:space:]]*)?(\*\*)?Findings:?(\*\*)?[[:space:]]*$'

  grep -Eiq "$evidence_heading" "$out_path" && grep -Eiq "$findings_heading" "$out_path"
}

base_reviewers=(code-reviewer security-reviewer silent-failure-hunter pr-test-analyzer comment-analyzer code-simplifier)
if [[ "$typed_diff" == "true" ]]; then
  base_reviewers+=(type-design-analyzer)
fi

reviewers=()
reviewer_base_names=()
reviewer_shard_labels=()
reviewer_packet_files=()
for packet_i in "${!packet_files[@]}"; do
  shard_number=$((packet_i + 1))
  shard_label="${shard_number}/${packet_count}"
  for reviewer in "${base_reviewers[@]}"; do
    reviewers+=("${reviewer}-shard-${shard_number}")
    reviewer_base_names+=("$reviewer")
    reviewer_shard_labels+=("$shard_label")
    reviewer_packet_files+=("${packet_files[$packet_i]}")
  done
done
required_count="${#reviewers[@]}"

if [[ -n "$output_file" ]]; then
  ensure_parent_dir "$output_file"
else
  output_file="$(mktemp "${TMPDIR:-/tmp}/pr-review-report.XXXXXX")"
fi
artifact_dir="${output_file}.artifacts"
reviewer_outputs_file="$artifact_dir/reviewer-outputs.md"
mkdir -p "$artifact_dir"
cp "$changed_files_tmp" "$artifact_dir/changed-files.txt"
cp "$all_changed_files_tmp" "$artifact_dir/all-changed-files.txt"
cp "$excluded_files_tmp" "$artifact_dir/excluded-files.txt"
cp "$guidance_tmp" "$artifact_dir/guidance.md"
for packet_path in "${packet_files[@]}"; do
  cp "$packet_path" "$artifact_dir/$(basename "$packet_path")"
done

if [[ -n "$raw_log" ]]; then
  ensure_parent_dir "$raw_log"
  : >"$raw_log"
  {
    printf 'wrapper.started\tscope=%s\n' "$scope_label"
    printf 'wrapper.workdir\t%s\n' "$tmp_root"
    printf 'wrapper.keep_tmp\t%s\n' "$keep_tmp"
    printf 'wrapper.include_lockfiles\t%s\n' "$include_lockfiles"
    printf 'wrapper.reviewers\t%s\n' "$(join_by ',' "${base_reviewers[@]}")"
    printf 'wrapper.shards\t%s\n' "$packet_count"
    printf 'wrapper.tasks\t%s\n' "$required_count"
    printf 'wrapper.all_changed_files\t%s\n' "$artifact_dir/all-changed-files.txt"
    printf 'wrapper.excluded_files\t%s\n' "$artifact_dir/excluded-files.txt"
    for packet_path in "${packet_files[@]}"; do
      printf 'wrapper.packet\tpath=%s\tbytes=%s\n' "$artifact_dir/$(basename "$packet_path")" "$(packet_size_bytes "$packet_path")"
    done
    printf 'wrapper.report_path\t%s\n' "$output_file"
    printf 'wrapper.artifact_dir\t%s\n' "$artifact_dir"
    printf 'wrapper.reviewer_outputs\t%s\n' "$reviewer_outputs_file"
  } >>"$raw_log"
fi

reviewer_prompt_files=()
reviewer_raw_files=()
reviewer_out_files=()
reviewer_pids=()
reviewer_states=()
reviewer_exit_codes=()

for reviewer in "${reviewers[@]}"; do
  task_i="${#reviewer_prompt_files[@]}"
  base_reviewer="${reviewer_base_names[$task_i]}"
  shard_label="${reviewer_shard_labels[$task_i]}"
  packet_path="${reviewer_packet_files[$task_i]}"
  reviewer_prompt="$tmp_root/$reviewer.prompt"
  reviewer_raw="$tmp_root/$reviewer.raw"
  reviewer_out="$tmp_root/$reviewer.out"

  write_reviewer_prompt "$base_reviewer" "$reviewer_prompt" "$packet_path" "$shard_label"

  reviewer_prompt_files+=("$reviewer_prompt")
  reviewer_raw_files+=("$reviewer_raw")
  reviewer_out_files+=("$reviewer_out")
  reviewer_states+=("running")
  reviewer_exit_codes+=("")

  if [[ -n "$raw_log" ]]; then
    printf 'reviewer.started\tname=%s\tbase=%s\tshard=%s\tpacket=%s\traw=%s\toutput=%s\n' \
      "$reviewer" "$base_reviewer" "$shard_label" "$artifact_dir/$(basename "$packet_path")" "$artifact_dir/$reviewer.raw.jsonl" "$artifact_dir/$reviewer.out.md" >>"$raw_log"
  fi

  (
    set +e
    run_codex_prompt "$reviewer_prompt" "$reviewer_out" "$reviewer_raw"
  ) &
  reviewer_pids+=("$!")
done

last_progress=""
last_progress_at=0

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
    reviewer_exit_codes[i]="$exit_code"

    fail_reason=""
    if [[ "$exit_code" -ne 0 ]]; then
      fail_reason="exit=$exit_code"
    elif [[ ! -s "$reviewer_out" ]]; then
      fail_reason="empty-output"
    elif grep -Eq '(^REVIEW FAILED$|^Missing reviewers:|REVIEW FAILED[[:space:]]*$)' "$reviewer_out"; then
      fail_reason="invalid-output"
    elif ! reviewer_output_has_evidence "$reviewer_out"; then
      fail_reason="missing-review-evidence"
    fi

    if [[ -n "$fail_reason" ]]; then
      reviewer_states[i]="failed:$fail_reason"
      unresolved_parts+=("${reviewer}($fail_reason)")
      if [[ -n "$raw_log" ]]; then
        printf 'reviewer.failed\tname=%s\treason=%s\texit=%s\traw=%s\toutput=%s\n' \
          "$reviewer" "$fail_reason" "$exit_code" "$artifact_dir/$reviewer.raw.jsonl" "$artifact_dir/$reviewer.out.md" >>"$raw_log"
      fi
    else
      reviewer_states[i]="success"
      completed_count=$((completed_count + 1))
      if [[ -n "$raw_log" ]]; then
        printf 'reviewer.completed\tname=%s\texit=%s\traw=%s\toutput=%s\n' \
          "$reviewer" "$exit_code" "$artifact_dir/$reviewer.raw.jsonl" "$artifact_dir/$reviewer.out.md" >>"$raw_log"
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

  if [[ "$active_count" -eq 0 ]]; then
    break
  fi

  sleep 2
done

{
  printf '# Reviewer Outputs\n\n'
  printf 'Review scope: %s\n\n' "$scope_label"
  printf 'Packet shards: %s\n\n' "$packet_count"
  for i in "${!reviewers[@]}"; do
    reviewer="${reviewers[$i]}"
    base_reviewer="${reviewer_base_names[$i]}"
    shard_label="${reviewer_shard_labels[$i]}"
    packet_path="${reviewer_packet_files[$i]}"
    reviewer_out="${reviewer_out_files[$i]}"
    reviewer_raw="${reviewer_raw_files[$i]}"
    reviewer_prompt="${reviewer_prompt_files[$i]}"
    reviewer_artifact_out="$artifact_dir/$reviewer.out.md"
    reviewer_artifact_raw="$artifact_dir/$reviewer.raw.jsonl"
    reviewer_artifact_prompt="$artifact_dir/$reviewer.prompt.md"

    [[ -f "$reviewer_out" ]] && cp "$reviewer_out" "$reviewer_artifact_out"
    [[ -f "$reviewer_raw" ]] && cp "$reviewer_raw" "$reviewer_artifact_raw"
    [[ -f "$reviewer_prompt" ]] && cp "$reviewer_prompt" "$reviewer_artifact_prompt"

    printf '## %s\n\n' "$reviewer"
    printf 'Base reviewer: %s\n\n' "$base_reviewer"
    printf 'Shard: %s\n\n' "$shard_label"
    printf 'Packet artifact: %s\n\n' "$artifact_dir/$(basename "$packet_path")"
    if [[ -s "$reviewer_out" ]]; then
      cat "$reviewer_out"
    else
      printf 'No reviewer output captured.\n'
    fi
    printf '\n\n'
  done
} >"$reviewer_outputs_file"

printf 'pr-review: reviewer outputs -> %s\n' "$reviewer_outputs_file" >&2
if [[ -n "$raw_log" ]]; then
  printf 'reviewer.outputs_preserved\tpath=%s\tartifact_dir=%s\n' "$reviewer_outputs_file" "$artifact_dir" >>"$raw_log"
fi

failed_reviewers=()
for i in "${!reviewers[@]}"; do
  if [[ "${reviewer_states[$i]}" != "success" ]]; then
    if [[ "${reviewer_states[$i]}" == failed:* ]]; then
      failed_reviewers+=("${reviewers[$i]}(${reviewer_states[$i]#failed:})")
    else
      failed_reviewers+=("${reviewers[$i]}(${reviewer_states[$i]})")
    fi
  fi
done

if [[ ${#failed_reviewers[@]} -gt 0 ]]; then
  echo "error: pr-review reviewers did not complete cleanly" >&2
  echo "error: failed reviewers: $(join_by ', ' "${failed_reviewers[@]}")" >&2
  echo "error: reviewer outputs: $reviewer_outputs_file" >&2
  echo "error: workdir: $tmp_root" >&2
  if [[ -n "$raw_log" ]]; then
    echo "error: raw log: $raw_log" >&2
  fi
  exit 3
fi

run_synthesis_checked() {
  local label="$1"
  local prompt_path="$2"
  local out_path="$3"
  local raw_path="$4"
  local prompt_bytes codex_status

  prompt_bytes="$(packet_size_bytes "$prompt_path")"
  if [[ "$prompt_bytes" -gt "$max_packet_bytes" ]]; then
    echo "error: pr-review synthesis prompt is too large for $label" >&2
    echo "error: prompt bytes: $prompt_bytes" >&2
    echo "error: max prompt bytes: $max_packet_bytes" >&2
    echo "error: reviewer outputs: $reviewer_outputs_file" >&2
    echo "error: artifact dir: $artifact_dir" >&2
    exit 3
  fi

  if [[ -n "$raw_log" ]]; then
    printf 'synthesis.started\tlabel=%s\traw=%s\toutput=%s\tbytes=%s\n' "$label" "$raw_path" "$out_path" "$prompt_bytes" >>"$raw_log"
  fi

  set +e
  run_codex_prompt "$prompt_path" "$out_path" "$raw_path"
  codex_status=$?
  set -e

  if [[ -n "$raw_log" ]]; then
    printf 'synthesis.completed\tlabel=%s\texit=%s\traw=%s\toutput=%s\n' "$label" "$codex_status" "$raw_path" "$out_path" >>"$raw_log"
  fi

  if [[ "$codex_status" -eq 124 ]]; then
    echo "error: pr-review synthesis timed out after ${review_timeout_seconds}s ($label)" >&2
    tail -n 40 "$raw_path" >&2 || true
    exit 3
  fi

  if [[ "$codex_status" -ne 0 ]]; then
    echo "error: pr-review synthesis exited with status $codex_status ($label)" >&2
    tail -n 40 "$raw_path" >&2 || true
    exit 3
  fi

  if [[ ! -s "$out_path" ]]; then
    echo "error: pr-review synthesis output was empty ($label)" >&2
    tail -n 40 "$raw_path" >&2 || true
    exit 3
  fi
}

report_has_completion_status() {
  local report_path="$1"
  local count="$2"

  python3 - "$report_path" "$count" <<'PY'
import re
import sys

report_path = sys.argv[1]
count = int(sys.argv[2])
pattern = re.compile(
    rf"^(?:completion status\s*[:\-]\s*)?{count}\s+of\s+{count}\s+agents\s+completed\.?$",
    re.IGNORECASE,
)

checked = 0
with open(report_path, "r", encoding="utf-8", errors="replace") as report:
    for raw in report:
        line = raw.strip()
        if not line:
            continue
        checked += 1
        line = line.replace("**", "").replace("__", "").replace("`", "")
        line = re.sub(r"^[#>\-\*\s]+", "", line).strip()
        if pattern.fullmatch(" ".join(line.split())):
            sys.exit(0)
        if checked >= 20:
            break

sys.exit(1)
PY
}

write_synthesis_rules() {
  local intro="$1"

  cat <<EOF
$intro

Rules:
- Do not use tools or spawn agents.
- Start the report with this exact line: ${required_count} of ${required_count} agents completed
- Preserve findings-first output
- Use **Critical Issues** for confidence >= 91
- Use **Important Issues** for confidence 75-90
- Deduplicate overlapping findings across reviewers
- Keep issues tied to changed behavior in this diff
- For code defects, keep only findings tied to ADDED or MODIFIED lines
- Missing-test findings may cite the changed behavior/file under review instead of a test-file line
- Preserve type-design, simplification, naming, and semantic-contract findings when they materially affect changed behavior, changed API surface, or future safety of a changed helper/module.
- Do not drop confidence >= 75 design-quality or test-coverage findings solely because they are not immediate runtime failures.
- Do not drop unique reviewer findings during dedupe. If you exclude a reviewer finding with confidence >= 75, add a brief **Dropped Reviewer Findings** section explaining why it was excluded.
- If nothing survives filtering, say exactly: No significant issues found.

EOF
}

shard_report_files=()
if [[ "$packet_count" -gt 1 ]]; then
  for packet_i in "${!packet_files[@]}"; do
    shard_number=$((packet_i + 1))
    shard_label="${shard_number}/${packet_count}"
    shard_prompt="$tmp_root/synthesis-shard-$shard_number.prompt"
    shard_raw="$tmp_root/synthesis-shard-$shard_number.raw"
    shard_out="$tmp_root/synthesis-shard-$shard_number.out"

    {
      write_synthesis_rules "Synthesize one shard-level PR review from completed reviewer outputs for shard $shard_label."
      cat <<EOF
Shard scope:

Scope: $scope_label
Shard: $shard_label
Packet artifact: $artifact_dir/$(basename "${packet_files[$packet_i]}")

Changed files in this shard:

${packet_file_lists[$packet_i]}

Reviewer outputs:

EOF

      for i in "${!reviewers[@]}"; do
        if [[ "${reviewer_shard_labels[$i]}" != "$shard_label" ]]; then
          continue
        fi
        reviewer="${reviewers[$i]}"
        base_reviewer="${reviewer_base_names[$i]}"
        reviewer_out="${reviewer_out_files[$i]}"
        printf '## %s\n' "$reviewer"
        printf 'Base reviewer: %s\n' "$base_reviewer"
        printf 'Shard: %s\n\n' "$shard_label"
        cat "$reviewer_out"
        printf '\n\n'
      done
    } >"$shard_prompt"

    run_synthesis_checked "shard-$shard_number" "$shard_prompt" "$shard_out" "$shard_raw"
    cp "$shard_prompt" "$artifact_dir/synthesis-shard-$shard_number.prompt.md"
    cp "$shard_raw" "$artifact_dir/synthesis-shard-$shard_number.raw.jsonl"
    cp "$shard_out" "$artifact_dir/synthesis-shard-$shard_number.out.md"
    if [[ -n "$raw_log" ]]; then
      printf 'synthesis.artifact\tlabel=shard-%s\tprompt=%s\traw=%s\toutput=%s\n' \
        "$shard_number" \
        "$artifact_dir/synthesis-shard-$shard_number.prompt.md" \
        "$artifact_dir/synthesis-shard-$shard_number.raw.jsonl" \
        "$artifact_dir/synthesis-shard-$shard_number.out.md" >>"$raw_log"
    fi
    shard_report_files+=("$shard_out")
  done
fi

{
  if [[ "$packet_count" -gt 1 ]]; then
    write_synthesis_rules "Synthesize the final PR review from completed shard-level review reports."
  else
    write_synthesis_rules "Synthesize a PR review from completed reviewer outputs across the frozen packet."
  fi

  cat <<EOF
Review scope:

Scope: $scope_label
Packet shards: $packet_count
Base reviewer set: $(join_by ', ' "${base_reviewers[@]}")
Artifact directory: $artifact_dir

Changed files:

$(cat "$changed_files_tmp")

Files excluded from reviewer packets:

$(
  if [[ -s "$excluded_files_tmp" ]]; then
    cat "$excluded_files_tmp"
  else
    printf 'None.\n'
  fi
)

Reviewer outputs:

EOF

  if [[ "$packet_count" -gt 1 ]]; then
    for i in "${!shard_report_files[@]}"; do
      shard_number=$((i + 1))
      printf '## Shard %s/%s Report\n\n' "$shard_number" "$packet_count"
      cat "${shard_report_files[$i]}"
      printf '\n\n'
    done
  else
    for i in "${!reviewers[@]}"; do
      reviewer="${reviewers[$i]}"
      base_reviewer="${reviewer_base_names[$i]}"
      shard_label="${reviewer_shard_labels[$i]}"
      reviewer_out="${reviewer_out_files[$i]}"
      printf '## %s\n' "$reviewer"
      printf 'Base reviewer: %s\n' "$base_reviewer"
      printf 'Shard: %s\n\n' "$shard_label"
      cat "$reviewer_out"
      printf '\n\n'
    done
  fi
} >"$prompt_file"
cp "$prompt_file" "$artifact_dir/synthesis.prompt.md"

printf 'pr-review: synthesis started -> %s\n' "$output_file" >&2
run_synthesis_checked "final" "$prompt_file" "$out_file" "$raw_file"
[[ -f "$raw_file" ]] && cp "$raw_file" "$artifact_dir/synthesis.raw.jsonl"
[[ -f "$out_file" ]] && cp "$out_file" "$artifact_dir/synthesis.out.md"
if [[ -n "$raw_log" ]]; then
  printf 'synthesis.artifact\tlabel=final\tprompt=%s\traw=%s\toutput=%s\n' \
    "$artifact_dir/synthesis.prompt.md" \
    "$artifact_dir/synthesis.raw.jsonl" \
    "$artifact_dir/synthesis.out.md" >>"$raw_log"
  fi

cp "$out_file" "$output_file"

if ! report_has_completion_status "$output_file" "$required_count"; then
  echo "error: pr-review output did not include completion status" >&2
  echo "error: synthesis report preserved at $output_file" >&2
  cat "$output_file" >&2
  exit 3
fi

printf 'pr-review: final report path %s\n' "$output_file" >&2
printf 'pr-review: artifacts %s\n' "$artifact_dir" >&2
if [[ "$keep_tmp" == "1" ]]; then
  printf 'pr-review: workdir preserved %s\n' "$tmp_root" >&2
fi
echo "$output_file"
