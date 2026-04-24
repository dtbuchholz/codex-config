---
name: pr-review
description:
  Comprehensive PR review using a fixed parallel reviewer set over one frozen review packet.
argument-hint: "[range:<git-range>]"
---

# PR Review

Use the bundled wrapper script. The wrapper freezes review scope first, runs the fixed specialist
reviewer set in parallel, and collates findings only after all required reviewers finish.

## Immediate Action

From the current repo root, run:

```bash
"$HOME/.codex/skills/pr-review/scripts/run-pr-review.sh" "$(pwd)"
```

Pass through supported arguments from the user request:

- `range:<git-range>` -> `--range <git-range>`

If you want raw event diagnostics, add:

```bash
--raw-log "$(mktemp "${TMPDIR:-/tmp}/pr-review-raw.XXXXXX")"
```

## Contract

- freeze the review scope before spawning any reviewers
- run the fixed reviewer set in parallel: `code-reviewer`, `security-reviewer`,
  `silent-failure-hunter`, `pr-test-analyzer`, `comment-analyzer`
- include `type-design-analyzer` only when the diff includes typed-language files
- require modified-lines-only reporting
- wait for every required reviewer before synthesis
- fail the review if any required reviewer does not complete cleanly
- do not return partial-review success

## After Success

- read the report file path printed by the script
- present the findings-only result to the user
- preserve the report's completion status and confidence buckets

## After Failure

- report the exact failure
- if a raw log path was used, include it in the error report
- do not pretend the review completed
