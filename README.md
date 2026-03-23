# Codex CLI Configuration

Shared configuration for Codex CLI to ensure consistent tooling, workflows, and best practices.

## Install

```bash
git clone <repo-url> ~/.codex
cd ~/.codex
make config-init
make setup
```

`config.toml` is machine-local and gitignored. Keep user-specific project trust entries there.

## What's Included

- `skills/` — task skills (invokable as slash commands)
- `agents/` — specialized agent personas
- `hooks/` — local helper scripts (e.g., notifications)
- `policy/` — command allowlist
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

MCP config (`.mcp.json`) should use a portable command so it works across machines:

```json
{
  "mcpServers": {
    "qmd": {
      "command": "qmd",
      "args": ["mcp"]
    }
  }
}
```

For date-specific recall from conversation digests:

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

## Notifications

This repo wires Codex's native `notify` option to `hooks/notify.sh` via `hooks/notify-codex.py`.
Install a notification backend if desired:

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

## Using CODEX.md

Copy `CODEX.md.template` into a project root and customize it:

```bash
cp ~/.codex/CODEX.md.template /path/to/project/CODEX.md
```

## Notes

- Some Claude-specific hook behaviors are not available in Codex; see `hooks/` for what is wired.
