---
name: adjudicate
description:
  Adjudicate review feedback from another agent or reviewer, decide what you agree or disagree with,
  implement the warranted changes, and commit if requested. Use when the user pastes review findings
  and asks you to determine whether you agree, apply fixes, and optionally commit.
---

# Adjudicate

Use this when the user brings feedback from a separate reviewer and wants the implementer agent to
judge it rather than apply it blindly.

Typical trigger:

```text
I had an agent review these commits. Determine if you agree or disagree with its feedback, and then
implement any changes as needed, and commit.
```

## Core Rule

Do not treat reviewer feedback as automatically correct. Check every finding against the real diff,
the current code, and any relevant contracts or tests before changing code.

## Workflow

### 1. Freeze The Scope

Identify exactly what is being reviewed:

- explicit commit range such as `HEAD~2..HEAD`
- current branch diff
- unstaged/staged working tree
- files named in the pasted review

Inspect that real scope first before acting on the feedback.

### 2. Parse The Review Feedback

Break the pasted feedback into concrete findings. For each one, capture:

- file and line, if provided
- claimed bug or risk
- confidence/severity, if provided
- whether the reviewer is describing behavior, tests, contracts, comments, or types

### 3. Adjudicate Finding By Finding

For each finding, decide one of:

- `Agree`: the issue is real and should be fixed
- `Disagree`: the reviewer is wrong, stale, off-scope, or misread the code
- `Partially agree`: the concern is directionally right but the proposed reasoning or fix is not

When adjudicating, verify against:

- the actual modified lines
- surrounding code paths
- API/client/parser/data contracts
- tests and runtime assumptions, when relevant

Do not "fix" something just because it sounds plausible.

### 4. Implement Only The Warranted Changes

Apply fixes for findings you agree with.

If you disagree but the code is genuinely confusing, prefer a clarifying rename, comment, or small
refactor rather than a behavior change.

Do not broaden scope without a concrete reason tied to the reviewed change.

### 5. Validate

Run the narrowest useful validation for the changed surface:

- targeted tests
- lint/typecheck for touched files or package
- focused smoke checks when tests are unavailable

If you cannot validate, say so explicitly.

### 6. Commit Only If Requested

If the user asked to commit, create one conventional commit after the fixes and validation.

If the user did not ask to commit, stop after the code changes and summary.

## Output

Lead with the adjudication, not the patch inventory.

Preferred structure:

```text
Agreed:
- ...

Disagreed:
- ...

Partially agreed:
- ...

Implemented:
- ...

Validation:
- ...

Commit:
- <hash> <message>
```

If there are no warranted changes, say so plainly and do not invent fixes.

## Notes

- Keep the reviewer feedback neutral in tone when handing it back to the implementer agent.
- Validate review findings against real contracts before accepting them.
- If the review is diff-scoped, keep the adjudication diff-scoped too.
