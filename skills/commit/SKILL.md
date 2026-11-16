---
name: commit
description: Create a git commit with conventional commit format.
---

# Git Commit

Create a single, well-formatted git commit following conventional commits.

## When This Skill Applies

- User asks to commit changes
- User says "$commit" or "commit this"

## Context

Run `git status`, `git diff HEAD`, `git branch --show-current`, and `git log --oneline -10` to
inspect the current changes. Skill Markdown does not execute shell interpolation.

## Your Task

Based on the above changes, create a single git commit.

### Conventional Commit Format

Use conventional commit prefixes:

- `feat:` new feature
- `fix:` bug fix
- `refactor:` code refactoring
- `docs:` documentation changes
- `test:` test additions/changes
- `chore:` maintenance tasks
- `perf:` performance improvements
- `style:` formatting, whitespace

### Commit Message Guidelines

- First line: `<type>: <short description>` (50 chars max)
- Commit body is REQUIRED for all non-trivial commits
- Body must follow this structure:
  - `What:` concrete summary of changes
  - `Why:` motivation / problem solved
- Trivial exception: allow subject-only commit only when change is extremely small (e.g., typo,
  comments-only, or formatting-only) and no behavior change
- Reference issues with `Fixes #123` or `Closes #123`

Preferred format:

```text
<type>: <short description>

What:
- ...

Why:
- ...
```

When creating the commit, provide subject and body explicitly (for example with multiple `-m` flags,
or equivalent) so body is not omitted.

### Execution

Inspect the diff before staging. Stage only the requested files, respect existing git hooks, create
the commit, and verify the resulting status. Report the commit hash and subject.
