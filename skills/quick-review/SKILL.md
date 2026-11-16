---
name: quick-review
description:
  Review a small change comprehensively in the current session, without subagents or separate
  reviewer processes. Use for focused feedback on a patch, selected files, or current changes;
  report findings without editing.
---

# Quick Review

Review directly in the current session. Do not spawn subagents, start another Codex/Claude process,
or invoke the specialist pipeline. Reduce orchestration and unrelated exploration, not the quality
of the review. This review shares the current conversation's implementation context.

## Establish Scope

Honor the user's selected files, diff, commit, or base branch. Otherwise review current staged,
unstaged, and untracked changes. Inspect applicable `AGENTS.md` instructions.

```bash
git status --short
git diff HEAD --no-ext-diff
git ls-files --others --exclude-standard
```

Read relevant untracked files themselves; listing their names is not reviewing their contents. For a
repository without HEAD, inspect staged and unstaged diffs separately. For an explicit branch or
commit, use that target rather than silently switching to the working tree. If the selected scope
has no changes, say so and stop.

## Review

Read the changed code and enough surrounding context to assess its behavior. Follow direct callers,
callees, types, configuration, and nearby tests when needed to verify a concern. Avoid arbitrary
file-count limits, broad repository audits, and unrelated cleanup.

Consider each relevant dimension in one pass:

- Correctness: behavior changes, invariants, edge cases, and regressions, including deleted code.
- Boundaries: input validation, authorization, data exposure, and compatibility with callers.
- Failure paths: error propagation, cleanup, retries, concurrency, and state transitions.
- Tests: whether coverage would catch the concrete regression or important new behavior.
- Clarity and efficiency: misleading contracts, consequential complexity, or performance issues
  introduced by the change. Omit cosmetic preferences and speculative redesigns.

Verify candidate findings against the actual implementation before reporting them. Use focused,
non-mutating checks when they would resolve uncertainty; do not install dependencies, regenerate
files, or run the full suite by default. If a check would modify project state, describe the needed
verification instead. A code review alone does not establish that tests pass.

Do not edit files, stage changes, or commit. If the scope proves larger than expected, complete the
useful inspection possible in this session and state any unreviewed areas. Recommend a separate
review if warranted, without launching one automatically.

## Report

Lead with actionable findings ordered by severity. For each, include a file/line reference, the
triggering condition, concrete impact, and a concise fix direction. Separate impact from confidence;
do not invent numeric confidence scores or require a quota of findings.

Then briefly state the scope reviewed, checks actually run, and material uncertainties. If no
actionable issues were found, say so explicitly and note relevant coverage limits. Keep the result
concise without omitting important findings.
