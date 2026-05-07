---
name: pr-review
description:
  Comprehensive PR review using a fixed parallel reviewer set over frozen bounded review packets.
argument-hint: "[range:<git-range>] [path:<pathspec>] [include-lockfiles]"
---

# PR Review

Use the bundled wrapper script. The wrapper freezes review scope first, shards oversized diffs into
bounded frozen packets, runs the fixed specialist reviewer set in parallel, and collates findings
only after all required reviewers finish. It preserves the temp workdir by default so reviewer
prompts, raw outputs, and packet files remain inspectable until the OS cleans `/tmp`.

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
- run the fixed reviewer set in parallel: `code-reviewer`, `security-reviewer`,
  `silent-failure-hunter`, `pr-test-analyzer`, `comment-analyzer`, `code-simplifier`
- include `type-design-analyzer` only when the diff includes typed-language files
- default to richer frozen diff context (`--context-lines 40`) while keeping the review scoped to
  the selected diff
- require changed-behavior reporting: code defects must cite added/modified lines, while
  missing-test findings may cite the changed behavior or file that needs coverage
- keep semantic-contract, naming/control-plane, type-design, simplification, and unit-test gap
  findings in scope when they materially affect changed behavior, changed API surface, or future
  safety of a changed helper/module
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
- do not return partial-review success

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
