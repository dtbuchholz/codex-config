---
name: dev-loop
description: >
  Run a thin multi-agent development loop across Claude Code and Codex CLI: implement, review, apply
  fixes, and run a final holistic review with filesystem handoff artifacts.
---

# Dev Loop

Orchestrate a repeatable cross-CLI flow using local files as the context contract.

## When This Skill Applies

- User asks for automated Claude+Codex collaboration
- User wants implement -> review -> fix -> final review without manual copy/paste
- User references "dev loop", "handoff", or "orchestrator"

## Script

Primary entrypoint:

```bash
~/.codex/scripts/dev-loop.sh
```

Artifacts are written to:

```text
<project>/.dev-loop/
```

Key files:

- `phase1-handoff.md`
- `phase2-review.md`
- `phase3-apply.md`
- `phase4-final.md`

## Usage

Default (project is current directory, spec is `SPEC.md`):

```bash
~/.codex/scripts/dev-loop.sh
```

Explicit project/spec:

```bash
~/.codex/scripts/dev-loop.sh -C /path/to/repo -s /path/to/repo/SPEC.md
```

Skip initial implement pass (review/fix loop only):

```bash
~/.codex/scripts/dev-loop.sh -C /path/to/repo -s /path/to/repo/SPEC.md --skip-implement
```

Tune diff size to avoid oversized prompt payloads:

```bash
~/.codex/scripts/dev-loop.sh --max-diff-chars 40000
```

## Preconditions

- `claude`, `codex`, `jq`, and `git` are installed and available in `PATH`
- Target project is a git repo
- Spec file exists
- Both CLIs are authenticated

## Notes

- Script passes `--project-dir` to Claude and `-C` to Codex for stable context binding
- Diffs are truncated (configurable) before prompt embedding to avoid oversized requests
- This skill is orchestration-only; it does not replace project-specific review/testing skills
