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
~/.codex/scripts/qmd.sh search "exact term"
~/.codex/scripts/qmd.sh vsearch "conceptual query"
~/.codex/scripts/qmd.sh query "open-ended question" -n 6 --md
```

Use the wrapper script to avoid Node/NVM path drift across versions.

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
