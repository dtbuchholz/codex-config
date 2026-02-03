# Codex CLI Configuration

Shared configuration for Codex CLI to ensure consistent tooling, workflows, and best practices.

## Install

```bash
git clone <repo-url> ~/.codex
```

## What's Included

- `skills/` — task skills (invokable as slash commands)
- `agents/` — specialized agent personas
- `hooks/` — local helper scripts (e.g., notifications)
- `policy/` — command allowlist
- `CODEX.md.template` — project context template

## Notifications

This repo wires Codex's native `notify` option to `hooks/notify.sh` via `hooks/notify-codex.py`.
Install a notification backend if desired:

- macOS: `brew install terminal-notifier`
- Linux: `notify-send` (libnotify)

## Using CODEX.md

Copy `CODEX.md.template` into a project root and customize it:

```bash
cp ~/.codex/CODEX.md.template /path/to/project/CODEX.md
```

## Notes

- Some Claude-specific hook behaviors are not available in Codex; see `hooks/` for what is wired.
