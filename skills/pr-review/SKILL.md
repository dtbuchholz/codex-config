---
name: pr-review
description:
  Comprehensive PR review using a fixed reviewer set over frozen bounded review packets, defaulting
  to thorough read-only context review with artifact-preserved candidate findings.
argument-hint: "[range:<git-range>] [path:<pathspec>] [context:<file>] [fast] [include-lockfiles]"
---

# PR Review

Use the bundled wrapper script. The wrapper freezes review scope first, shards oversized diffs into
bounded frozen packets, runs a fixed specialist reviewer set, and collates findings only after all
required reviewers finish. Thorough mode is the default: first-wave reviewers may inspect read-only
repo context, and `code-simplifier` runs after them with their outputs. Fast mode preserves the
older diff-only/no-tools reviewer contract.

The wrapper preserves the temp workdir by default so reviewer prompts, raw outputs, packet files,
first-wave outputs, and lower-confidence candidate findings remain inspectable until the OS cleans
`/tmp`.

## Immediate Action

From the current repo root, run:

```bash
"$HOME/.codex/skills/pr-review/scripts/run-pr-review.sh" "$(pwd)"
```

Pass through supported arguments from the user request:

- `range:<git-range>` -> `--range <git-range>`
- `context-lines:<n>` -> `--context-lines <n>`
- `path:<pathspec>` -> `--path <pathspec>` (repeat for multiple path filters)
- `max-packet-bytes:<n>` -> `--max-packet-bytes <n>`
- `context:<file>` or `acceptance-context:<file>` -> `--acceptance-context <file>` when the user
  provides a plan, issue, implementation intent, or acceptance criteria
- `fast` -> `--fast` only when the user explicitly wants the old 1-2 minute diff-only review path
- `mode:fast` or `mode:thorough` -> `--mode fast|thorough`
- `candidate-threshold:<n>` -> `--candidate-threshold <n>`; thorough mode defaults to `60`, fast
  mode defaults to `75`
- `include-lockfiles` -> `--include-lockfiles` when dependency lockfile changes are the intended
  review target
- `keep-tmp` -> `--keep-tmp`
- `cleanup-tmp` -> `--cleanup-tmp` only if the user explicitly wants temp files removed

If you want raw event diagnostics, add:

```bash
--raw-log "$(mktemp "${TMPDIR:-/tmp}/pr-review-raw.XXXXXX")"
```

## Contract

- freeze the review scope before running reviewers
- keep every inline reviewer packet below the configured packet-size cap; fail before reviewer
  launch if one file cannot fit in a bounded packet
- exclude common dependency lockfiles from reviewer packets by default, while preserving
  `all-changed-files.txt` and `excluded-files.txt` artifacts; use `--include-lockfiles` to review
  lockfile hunks intentionally
- shard large diffs by changed file and run the same reviewer set for each shard
- default to thorough mode; use fast mode only when the user asks for speed or explicitly requests
  it
- in thorough mode, allow reviewers to use read-only context inspection for changed files, nearby
  tests, project guidance, existing helper patterns, and git diff context; never edit files or run
  mutating commands from a reviewer prompt
- run first-wave reviewers in parallel: `code-reviewer`, `security-reviewer`,
  `silent-failure-hunter`, `pr-test-analyzer`, and `comment-analyzer`
- include `type-design-analyzer` only when the diff includes typed-language files
- run `code-simplifier` as a second phase after first-wave reviewer outputs are captured, with the
  changed files, diff packet, and first-wave findings as context
- report progress per phase, such as `first-wave 4/5` and then `code-simplifier 0/1`, rather than
  counting reviewers that are not eligible to launch yet
- default to richer frozen diff context (`--context-lines 40`) while keeping the review scoped to
  the selected diff
- pass acceptance context into the packet when the user provides a plan, issue link text, or stated
  behavior contract; reviewers should check changed behavior against that intent
- require changed-behavior reporting: code defects must cite added/modified lines, while
  missing-test findings may cite the changed behavior or file that needs coverage
- require `pr-test-analyzer` to compare changed behavior against nearby tests in thorough mode and
  report concrete missing negative/error-path/state-transition coverage when a regression could slip
  through
- give thorough-mode `silent-failure-hunter` a bounded context prompt and a longer default timeout
  via `PR_REVIEW_SILENT_FAILURE_TIMEOUT_SECONDS` (default `600`) because that role is the most
  likely to inspect surrounding failure paths
- keep semantic-contract, naming/control-plane, type-design, simplification, and unit-test gap
  findings in scope when they materially affect changed behavior, changed API surface, or future
  safety of a changed helper/module
- collect reviewer findings down to the reviewer candidate threshold, but keep the final report at
  `Critical Issues` for confidence `>=91` and `Important Issues` for confidence `75-90`; preserve
  `60-74` candidates in artifacts by default instead of promoting them into the final report
- write raw lifecycle events with timestamps and durations for reviewer and synthesis steps
- wait for every required reviewer before synthesis
- require each reviewer to include `Review evidence:` and `Findings:` sections; common Markdown
  heading variants such as `**Review evidence:**` are accepted, but a bare
  `No significant issues found.` reviewer response is a failed review, not success
- wait for all launched reviewer processes to settle before reporting reviewer contract failures;
  report exact reviewer names and reasons instead of cancelling the remaining reviewers on the first
  malformed output
- synthesize shard-level reports first when the review scope is split across multiple packets
- preserve per-reviewer prompts, raw logs, outputs, combined reviewer output artifacts, and the
  wrapper temp workdir by default
- fail the review if any required reviewer does not complete cleanly
- do not return partial-review success; on reviewer failure, preserve a
  `FAILED REVIEW - PARTIAL OUTPUTS` report at the requested output path and in artifacts so
  completed reviewer findings are recoverable without treating the run as successful

## After Success

- read the report file path printed by the script
- present the findings-only result to the user
- preserve the report's completion status and confidence buckets
- if synthesis quality is questioned, inspect the printed artifact directory and
  `reviewer-outputs.md` before rerunning

## After Failure

- report the exact failure
- include the reviewer output artifact path and raw log path when available
- do not pretend the review completed
