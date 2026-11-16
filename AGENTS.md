# AGENTS

This repository contains Codex CLI configuration, skills, and agents.

## Skills

Skills live under `skills/` and are invoked automatically based on metadata or manually via
`$skill-name` (use `/skills` to browse in the CLI).

## Agents

Custom agents live in standalone `agents/*.toml` files and can be requested by their configured
name.

## Templates

Use `CODEX.md.template` as a source for project-level `AGENTS.md` files. `CODEX.md` is a legacy
fallback filename enabled in this repo's configuration.

Run `make compatibility-check` after CLI upgrades to validate configuration, skills, agents, and
feature flags used by local scripts.
