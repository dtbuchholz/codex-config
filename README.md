# Codex CLI Configuration

Shared configuration for Codex CLI to ensure consistent tooling, workflows, and best practices.

## Install

```bash
git clone <repo-url> ~/.codex
cd ~/.codex
make config-init
make setup
```

`config.toml` is currently tracked and also contains machine-local, app-managed settings and project
trust entries. Use `config.toml.template` for a portable starting point, and review config diffs
before committing.

## What's Included

- `skills/` — task skills (invoke with `$skill-name`; browse with `/skills`)
- `agents/*.toml` — custom Codex agents with inherited model settings and permissions
- `hooks/` — local helper scripts (e.g., notifications)
- `policy/` — optional command rule examples (not automatically loaded)
- `CODEX.md.template` — project context template

## QMD Search

QMD provides semantic search across skills, memory, and config docs.

Install:

```bash
make qmd-install
```

Typical usage:

```bash
qmd search "exact term"
qmd vsearch "conceptual query"
qmd query "open-ended question" -n 6 --md
```

Standalone CLI MCP servers are configured in `config.toml`; plugins may package `.mcp.json`. For an
optional QMD server, use a portable command:

```toml
[mcp_servers.qmd]
command = "qmd"
args = ["mcp"]
```

For date-specific lookup from conversation digests:

```bash
~/.codex/scripts/qmd-temporal-recall.py "last Tuesday" "what did I do?" --source both --top 5
~/.codex/scripts/qmd-temporal-recall.py "2026-02-24" "qmd node mismatch" --source codex
```

## Dev Loop (Claude + Codex)

Use a thin orchestrator to automate:

1. Claude implementation from spec
2. Codex review of current diff
3. Claude application of review fixes
4. Claude final holistic review

Run with defaults (`PROJECT=$(pwd)`, `SPEC=<project>/SPEC.md`):

```bash
make dev-loop
```

Or run directly:

```bash
~/.codex/scripts/dev-loop.sh -C /path/to/repo -s /path/to/repo/SPEC.md
```

Useful flags:

```bash
~/.codex/scripts/dev-loop.sh --skip-implement
~/.codex/scripts/dev-loop.sh --skip-fix
~/.codex/scripts/dev-loop.sh --max-diff-chars 40000
```

Artifacts are written under:

```text
<project>/.dev-loop/
```

## Reviews

`$pr-review` runs one native Codex review in a separate read-only session. `$review-and-fix` uses
the same runner, adjudicates findings, applies accepted fixes, and validates them. It commits only
when requested.

```bash
~/.codex/skills/pr-review/scripts/run-pr-review.sh /path/to/repo --uncommitted
~/.codex/skills/pr-review/scripts/run-pr-review.sh /path/to/repo --base main
~/.codex/skills/pr-review/scripts/run-pr-review.sh /path/to/repo --commit HEAD
```

Reports, event logs, stderr, and run metadata are preserved in temporary artifacts by default. Use
`--output-file` for a persistent report. The native runner detects checkout changes during a review
and marks that result incomplete.

For an explicitly requested specialist review, add `--deep`. The retained multi-reviewer pipeline
has its own [options and contract](skills/pr-review/references/deep-review.md). It preserves frozen
diff packets but reads live repository context, so avoid editing that checkout while it runs.

## Notifications

The active machine config routes `notify` to the installed computer-use client. The scripts
`hooks/notify-codex.py` and `hooks/notify.sh` are optional alternative backends. cmux also injects
its own Codex hooks for session tracking and notifications. Install a backend for the optional
scripts if desired:

- macOS: `brew install terminal-notifier`
- Linux: `notify-send` (libnotify)

## Secret Scanning

Git hooks enforce secret scanning for both commits and pushes using `gitleaks`:

- `.husky/pre-commit` scans staged changes
- `.husky/pre-push` scans outgoing commits

Install requirement:

```bash
make gitleaks-install
```

If hooks stop working after dependency changes:

```bash
make hooks-install
make hooks-verify
make skills-lint
```

Emergency bypass (not recommended):

```bash
SKIP_GITLEAKS=1 git commit ...
SKIP_GITLEAKS=1 git push ...
```

## Project Instructions

Create a project `AGENTS.md` from the template and customize it (merge if one already exists):

```bash
cp ~/.codex/CODEX.md.template /path/to/project/AGENTS.md
```

## Notes

- Some Claude-specific hook behaviors are not available in Codex; see `hooks/` for what is wired.
- `CODEX.md` is supported here through `project_doc_fallback_filenames`; Codex normally reads
  `AGENTS.md`. The repository's `CODEX.md` is retained as reference material.
- Run `make compatibility-check` after upgrading Codex. It validates every local skill and agent,
  parses config, and checks scripted feature flags against the installed CLI.
- Run `make review-wrapper-test` for the mocked review workflow. A successful `--help` invocation
  does not validate feature flag names; use `codex features list` or an actual startup check.
- `policy/allowed.rules` is an optional example. Codex automatically loads rules from
  `rules/*.rules`, not `policy/`; no allowlist is needed for the configured full-access mode.
