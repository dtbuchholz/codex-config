---
name: pr-review
description:
  Review uncommitted changes, a branch, or a commit using native Codex review. Use an optional
  specialist pipeline only for explicitly requested deep reviews.
---

# PR Review

Run a separate, read-only Codex review using the shared runner. This skill reports findings; it does
not edit files or commit changes.

```bash
"$HOME/.codex/skills/pr-review/scripts/run-pr-review.sh" "$(pwd)" --uncommitted
```

## Scope

Choose the target requested by the user:

- No target or "current changes": `--uncommitted` (the default), including staged, unstaged, and
  untracked files. Do not fall back to unrelated branch commits when the working tree is clean.
- Branch/PR review: `--base <branch>`. Discover the intended base from the request or repository; do
  not assume every repo uses `main`.
- One commit: `--commit <sha>`.
- Arbitrary ranges or path-filtered specialist reviews: use `--deep` only when the user requested
  that deeper workflow; otherwise explain the native scope limitation before changing scope.

The native scope flags cannot be combined with a custom prompt. Put durable repository review
guidance in applicable `AGENTS.md` files. For a one-off acceptance file or custom criteria, use one
read-only `codex exec` with an explicit scope and those criteria instead of silently dropping the
criteria or escalating to the deep pipeline. Preserve its output and diagnostics.

## Review Against Acceptance Criteria

When a plan or acceptance file is supplied, assess both implementation behavior and whether required
tests meaningfully verify it. Report concrete verification gaps separately from runtime defects.
Include these criteria in the read-only review session's instructions.

For concurrency requirements, check that tests force the relevant interleaving through explicit
synchronization; simultaneous starts, sleeps, and immediate future-status assertions do not
establish deterministic coverage.

For important acceptance gates—such as numerical tolerances, cancellation, or supplied solver
seeds—check whether tests would detect the gate being removed or ignored. Use targeted read-only
probes when useful; mutation testing is optional.

Passing tests support only the behaviors they exercise. State unverified acceptance criteria
explicitly.

## Execution And Results

The shared runner uses `codex exec review`, disables memories, and starts a separate session with no
implementation conversation history. Skills and repository instructions can still load. Review
defaults to high reasoning effort; override using `--reasoning-effort <value>` or `--model <model>`
when requested or required by the selected model.

Optional runner flags: `--output-file <path>`, `--raw-log <path>`, `--timeout <seconds>` (default
600, or `PR_REVIEW_TIMEOUT_SECONDS`). Run without a PTY and wait for the process to finish.

- Read the report path printed on stdout; present actionable findings ordered by severity.
- Keep severity separate from confidence. Report defects introduced by the reviewed changes,
  including deletion-related regressions and defects in new files.
- If there are no findings, say so. Distinguish checks that passed from acceptance criteria that
  remain unverified; avoid implying full plan compliance from a passing suite. Note material
  coverage limits. A clean review is not a test run or proof of correctness.
- On nonzero exit, missing final output, timeout, or checkout drift, report the failure and artifact
  paths. Partial output is not a completed review. Do not retry repeatedly without resolving the
  cause.

The runner saves the final response, JSONL events, stderr, and run metadata. It fingerprints HEAD,
tracked diffs, and untracked file contents before and after review. This detects ordinary checkout
drift; it is not an immutable snapshot and cannot detect a temporary change reverted before
completion.

## Explicit Deep Review

When the user requests deep/specialist review, read
[references/deep-review.md](references/deep-review.md) and invoke the same runner with `--deep`.
This retains frozen diff packets, the specialist reviewer set, candidate artifacts, and synthesis.
It makes multiple model calls and can fail when any required reviewer fails. Frozen packets do not
freeze the live repository context reviewers inspect.
