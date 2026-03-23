---
name: repo-docs
description: >
  Bootstrap or audit agent-focused documentation for a repository. Init mode creates a tiered docs
  structure (AGENTS.md, AGENT-LEARNINGS.md, docs/, ADRs) tuned to repo complexity. Audit mode checks
  for staleness, coverage gaps, and drift.
argument-hint: "[init|audit]"
---

# Repo Docs

Bootstrap or audit agent-focused documentation for any repository. Creates a predictable,
hierarchical docs structure tuned to repo complexity, with both bootstrap and audit modes.

## When This Skill Applies

- `/repo-docs` or `/repo-docs init` — bootstrap or reorganize docs (default)
- `/repo-docs audit` — staleness and coverage check
- User asks to "set up docs for agents", "create AGENTS.md", "audit repo docs"

## Guard

You must be inside a git repository. Verify with:

```bash
git rev-parse --is-inside-work-tree
```

If not in a git repo, tell the user and stop.

## Mode Detection

- If the argument is `audit`, run **Audit Mode**
- Otherwise (no argument, `init`, or anything else), run **Init Mode**

---

## Init Mode

### Step 1: Scan

Launch 2 parallel sub-agents using `spawn_agent` with `agent_type: explorer` to gather repo
intelligence:

**Agent 1 — Structure & Stack:**

- Total source file count (exclude node_modules, .git, vendor, **pycache**, dist, build)
- Tech stack (languages, frameworks, package manager)
- Directory tree (2 levels deep)
- Entry points (main files, index files, CLI entry points)
- Existing documentation files (README, CONTRIBUTING, ARCHITECTURE, any .md files in docs/)
- Existing AGENTS.md, CLAUDE.md, CODEX.md (note their contents if present)

**Agent 2 — Commands & Conventions:**

- Package manager scripts (package.json scripts, Makefile targets, pyproject.toml scripts)
- Linter/formatter configs (ESLint, Prettier, Ruff, Black, etc.)
- Git hooks (husky, pre-commit, lefthook)
- Environment variables (.env.example, .env.local, or scanned from code)
- Test framework and test patterns (where tests live, how to run them)
- CI/CD config (GitHub Actions, etc.)
- Branch strategy (from branch protection, CONTRIBUTING, or convention)

Execution discipline:

- Dispatch both explorers first, then wait once for both results.
- Keep both scans read-only; parent agent owns synthesis and file writes.

### Step 2: Classify

Synthesize scan results and suggest a tier:

| Tier           | Signal                               | Docs Structure                                                 |
| -------------- | ------------------------------------ | -------------------------------------------------------------- |
| **1 (Small)**  | < 10 source files, single module     | AGENTS.md, AGENT-LEARNINGS.md, docs/decisions/, docs/README.md |
| **2 (Medium)** | 10–100 source files, multi-module    | Tier 1 + docs/how-to/, docs/reference/, docs/observations/     |
| **3 (Large)**  | 100+ source files, monorepo/platform | Tier 2 + docs/explanation/, docs/contracts/, docs/\_templates/ |

Present the classification to the user with reasoning and ask them to confirm or override the tier.

### Step 3: Scaffold

Create the directory structure for the confirmed tier. Only create directories and placeholder files
that don't already exist.

**Tier 1:**

```
docs/
├── decisions/
└── README.md
AGENTS.md
AGENT-LEARNINGS.md
```

**Tier 2:** (adds to Tier 1)

```
docs/
├── decisions/
├── how-to/
├── observations/
├── reference/
└── README.md
```

**Tier 3:** (adds to Tier 2)

```
docs/
├── decisions/
├── how-to/
├── observations/
├── reference/
├── explanation/
├── contracts/
├── _templates/
│   ├── how-to.md
│   ├── reference.md
│   └── explanation.md
└── README.md
```

### Step 3.5: File Naming Convention (Observations)

For dated observation files, enforce this format:

```text
YYYY-MM-DD-topic-kebab-case.md
```

Examples:

```text
2026-03-05-api-walkthrough-capture-analysis.md
2026-03-12-guest-query-endpoint-deep-dive.md
```

Do NOT use suffix-date filenames like:

```text
api-walkthrough-capture-analysis-2026-03-05.md
```

Living docs stay undated (for example `research-log.md`).

### Step 4: Generate AGENTS.md

Write a first-pass AGENTS.md populated with real values from the scan — not a skeleton with `[TODO]`
placeholders. Use the following template, filling every section from scan data:

```markdown
# [Project Name]

> [One-line description from package.json/pyproject.toml/README]

## Architecture

### Tech Stack

| Component       | Value      |
| --------------- | ---------- |
| Language        | [detected] |
| Framework       | [detected] |
| Package Manager | [detected] |
| Test Framework  | [detected] |
| CI/CD           | [detected] |

### Directory Structure

[Annotated tree, 2 levels deep — from scan]

### Key Modules

| Path   | Purpose   |
| ------ | --------- |
| [path] | [purpose] |

## Key Commands

| Command   | Description   |
| --------- | ------------- |
| [command] | [description] |

## Code Conventions

[Formatting, linting, git hooks, branch strategy — from detected configs]

## Environment Variables

| Variable | Description   | Required |
| -------- | ------------- | -------- |
| [var]    | [description] | [yes/no] |

If no .env.example or env vars were detected, omit this section.

## Agent Workflow

- Run [test command] before committing
- Follow existing patterns in the codebase
- Update docs when changing architecture or adding modules
```

If an AGENTS.md already exists, show the user a diff of what would change and ask before
overwriting.

### Step 5: Migrate

If existing documentation files were found during the scan:

1. List them and their current locations
2. Propose where they should move in the new structure (if anywhere)
3. Detect non-compliant observation filenames and propose rename mapping to date-prefix format
4. Ask the user before moving, renaming, or reorganizing anything

If no existing docs were found, skip this step.

### Step 6: Finalize

1. **Create symlinks** — CLAUDE.md and CODEX.md symlink TO AGENTS.md:

   ```bash
   ln -sf AGENTS.md CLAUDE.md
   ln -sf AGENTS.md CODEX.md
   ```

   If CLAUDE.md or CODEX.md already exist as real files (not symlinks), ask before replacing.

2. **Create ADR-001** — `docs/decisions/001-docs-structure.md`:

   ```markdown
   # ADR-001: Documentation Structure

   **Status:** Accepted **Date:** [today's date]

   ## Context

   This repository needed standardized, agent-friendly documentation to support both human
   developers and AI coding assistants. No consistent docs structure existed prior to this decision.

   ## Decision

   Adopted a Tier [N] documentation structure using the repo-docs convention:

   [List the directories and key files created]

   AGENTS.md serves as the canonical project reference. CLAUDE.md and CODEX.md are symlinks to
   AGENTS.md for compatibility with different AI tools.

   ## Consequences

   - All agent-facing context lives in AGENTS.md (single source of truth)
   - Operational learnings accumulate in AGENT-LEARNINGS.md
   - Architecture decisions are recorded in docs/decisions/
   - [Tier-specific consequences]
   ```

3. **Create docs/README.md** — An index of the docs structure:

   ```markdown
   # Documentation

   ## Structure

   | Directory  | Purpose                              |
   | ---------- | ------------------------------------ |
   | decisions/ | Architecture Decision Records (ADRs) |

   [Include only directories that exist for this tier]

   ## Key Files

   - **AGENTS.md** — Canonical project reference for AI agents and developers
   - **AGENT-LEARNINGS.md** — Operational insights from agent sessions
   - **CLAUDE.md / CODEX.md** — Symlinks to AGENTS.md

   ## Adding Documentation

   [Tier-appropriate guidance on where to put new docs]
   ```

4. **Generate AGENT-LEARNINGS.md:**

   ```markdown
   # Agent Learnings

   Operational insights from agent sessions. Newest first. Each entry includes a directive: a
   concrete "Do X, not Y" instruction.

   ---

   <!-- Entries below, newest first -->
   ```

### Doc Templates (Tier 3 Only)

Create these in `docs/_templates/`:

**how-to.md:**

```markdown
---
id: ""
title: ""
docType: how-to
summary: ""
owner: ""
lastReviewed: ""
codePaths: []
relatedDocs: []
---

# [Title]: How To

## Prerequisites

- [What the reader needs before starting]

## Steps

1. [Step]
2. [Step]

## Verification

- [How to confirm it worked]

## Troubleshooting

| Problem   | Solution |
| --------- | -------- |
| [symptom] | [fix]    |
```

**reference.md:**

```markdown
---
id: ""
title: ""
docType: reference
summary: ""
owner: ""
lastReviewed: ""
codePaths: []
relatedDocs: []
---

# [Title]: Reference

## Overview

[What this component/system is and its role]

## Configuration

| Option   | Type   | Default   | Description   |
| -------- | ------ | --------- | ------------- |
| [option] | [type] | [default] | [description] |

## API / Interface

[Endpoints, methods, or public interface]

## Examples

[Usage examples with expected output]
```

**explanation.md:**

```markdown
---
id: ""
title: ""
docType: explanation
summary: ""
owner: ""
lastReviewed: ""
codePaths: []
relatedDocs: []
---

# [Title]: Explanation

## Context

[Background and motivation — why does this exist?]

## Design Rationale

[Why this approach was chosen]

## Trade-offs

| Choice   | Benefit   | Cost   |
| -------- | --------- | ------ |
| [choice] | [benefit] | [cost] |

## Alternatives Considered

- **[Alternative]** — [Why it was rejected]
```

---

## Audit Mode

Audit mode is **read-only**. It reports findings and suggests actions but does not modify any files.

Run these 7 checks and compile a report:

### Check 1: Staleness

For each file in `docs/` and the root doc files (AGENTS.md, AGENT-LEARNINGS.md):

```bash
git log -1 --format="%ci" -- <file>
```

Flag any file last modified more than 90 days ago.

### Check 2: Coverage

Identify top-level code modules/packages (directories with source files). Check whether each has
corresponding documentation in docs/. A module without docs is a coverage gap.

### Check 3: Learnings Promotion

Read AGENT-LEARNINGS.md and look for recurring directives (similar entries appearing 3+ times).
Suggest promoting these to permanent docs (how-to or reference).

### Check 4: AGENTS.md Drift

Compare the AGENTS.md contents against reality:

- Do the listed commands still exist in package.json/Makefile/pyproject.toml?
- Does the directory structure description match the actual tree?
- Are listed env vars still present in .env.example or code?

Flag any mismatches.

### Check 5: Missing Docs Heuristic

Pattern-based detection of undocumented areas:

| Pattern Found                               | Expected Doc                  |
| ------------------------------------------- | ----------------------------- |
| Dockerfile or docker-compose.yml            | Deploy/infrastructure runbook |
| migrations/ directory                       | Database runbook              |
| API route files (routes/, api/, endpoints/) | API reference                 |
| .env.example with 10+ variables             | Configuration reference       |

### Check 6: Observation Filename Convention

If `docs/observations/` exists, validate filenames:

- Dated notes must match `^\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md$`
- Living docs (no date) are allowed only for explicitly designated files such as `research-log.md`

Flag non-compliant files and propose normalized rename targets.

### Check 7: Report

Compile all findings into a structured report:

```markdown
## Repo Docs Audit Report

### Summary

[One paragraph overview: overall health, biggest concerns]

### Stale Files

| File   | Last Modified | Days Stale |
| ------ | ------------- | ---------- |
| [file] | [date]        | [days]     |

### Coverage Gaps

| Module   | Status        |
| -------- | ------------- |
| [module] | No docs found |

### Promotion Candidates

| Directive   | Occurrences | Suggested Doc           |
| ----------- | ----------- | ----------------------- |
| [directive] | [count]     | [doc type and location] |

### AGENTS.md Drift

| Section   | Issue          |
| --------- | -------------- |
| [section] | [what's wrong] |

### Missing Docs

| Pattern   | Location | Suggested Doc |
| --------- | -------- | ------------- |
| [pattern] | [path]   | [doc type]    |

### Filename Convention Issues

| File   | Issue                  | Suggested Rename |
| ------ | ---------------------- | ---------------- |
| [path] | [non-compliant reason] | [new name]       |

### Suggested Actions

1. [Prioritized action items]
```

After the report, ask the user if they want to fix any of the findings.

---

## Rules

- Always ask before moving or reorganizing existing files
- Never overwrite existing AGENTS.md without confirmation
- Symlinks point TO AGENTS.md (CLAUDE.md → AGENTS.md, not reverse)
- Zero templates in Tier 1 and Tier 2 — templates only in Tier 3
- Audit mode is strictly read-only — report and suggest, never modify
- In `docs/observations/`, dated files must use date-prefix naming (`YYYY-MM-DD-topic.md`)
- When scanning, exclude common non-source directories: node_modules, .git, vendor, **pycache**,
  dist, build, .next, .turbo, coverage, .venv, venv
- If AGENTS.md generation can't determine a value, use a clear `[unknown]` marker rather than
  guessing incorrectly — accuracy over completeness
