---
name: review-and-fix
description:
  Review current changes in a separate Codex session, adjudicate findings, apply warranted fixes,
  and validate them. Commit only when requested.
---

# Review And Fix

Use the same review runner as `$pr-review`, then evaluate and fix findings in the current
implementation session. Default to a single native review of current uncommitted changes.

## Review

Inspect `git status --short` and applicable `AGENTS.md` guidance. Honor an explicit branch or commit
target; otherwise review staged, unstaged, and untracked changes together:

```bash
"$HOME/.codex/skills/pr-review/scripts/run-pr-review.sh" "$(pwd)" --uncommitted
```

Use `--base <branch>` or `--commit <sha>` for those targets. The helper starts a separate read-only
session, saves diagnostics, and prints the report path. Read that report after successful
completion. If review fails, surface its error and artifacts before applying review-driven changes.
Do not treat partial findings as a successful completed review.

For explicitly requested specialist/deep review, follow
[the deep review reference](../pr-review/references/deep-review.md) and add `--deep`. Do not launch
the specialist set simply because the normal reviewer is unavailable.

## Adjudicate And Fix

Check each finding against the actual code, requested behavior, and tests. Accept, reject, or adjust
it with a concrete reason. A confidence score alone is not evidence. Prioritize correctness,
security, regressions, and meaningful missing tests; avoid unrelated cleanup.

Apply accepted fixes in the current session so implementation context remains available. Preserve
unrelated working-tree changes. A review may find deletion-related defects or new-file bugs; do not
restrict findings to added diff lines.

## Validate

Run checks appropriate to the fixes before reporting success: focused regression tests and relevant
lint, typecheck, or build commands. For a behavior fix, demonstrate the regression with a failing
case before the fix when practical. Explain any checks that cannot run and their impact.

If a check fails because of the fixes, resolve it before continuing. Distinguish pre-existing
failures from new ones. If no relevant automated check exists, perform a focused smoke check and
state the remaining uncertainty.

For substantial fixes, or when requested, run one follow-up review against the updated scope. Keep
the scope aligned with the original target; a commit review alone will not include subsequent
uncommitted repairs. Do not call a repaired commit clean based only on re-reviewing its old SHA.
Stop after the initial repair pass and at most one follow-up review/repair pass unless the user
requests continued iteration. Report unresolved findings or failures rather than looping
indefinitely.

## Finish

Report accepted and rejected findings, fixes, verification results, remaining issues, and review
artifact paths. If there were no warranted fixes, say so.

Do not commit by default. When the user explicitly requests a commit, validate first, stage only the
intended changes, follow the commit skill, and report the commit hash. Never interpret invoking this
skill alone as authorization to commit.
