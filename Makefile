SHELL := /bin/bash

.PHONY: help setup deps config-init hooks-install hooks-verify gitleaks-install qmd-install dev-loop skills-lint

help:
	@echo "Available targets:"
	@echo "  make setup             Install dependencies and Husky hooks"
	@echo "  make deps              Install Node dependencies with pnpm"
	@echo "  make config-init       Create local config.toml from template"
	@echo "  make hooks-install     Install/reinstall Husky git hooks"
	@echo "  make hooks-verify      Verify expected hook files exist"
	@echo "  make gitleaks-install  Install gitleaks via Homebrew (macOS)"
	@echo "  make qmd-install       Install QMD via npm"
	@echo "  make dev-loop          Run Claude->Codex dev loop (set PROJECT= and SPEC= as needed)"
	@echo "  make skills-lint       Check skills for legacy Task/AskUserQuestion wording"

setup: deps hooks-install

deps:
	@pnpm install

config-init:
	@test -f config.toml || cp config.toml.template config.toml
	@echo "Local config.toml ready."

hooks-install:
	@pnpm run prepare

hooks-verify:
	@test -f .husky/pre-commit || (echo "Missing .husky/pre-commit" && exit 1)
	@test -f .husky/pre-push || (echo "Missing .husky/pre-push" && exit 1)
	@echo "Husky hooks are present."

gitleaks-install:
	@command -v brew >/dev/null 2>&1 || (echo "Homebrew not found. Install gitleaks manually." && exit 1)
	@brew install gitleaks

qmd-install:
	@command -v npm >/dev/null 2>&1 || (echo "npm not found. Install Node.js/npm first." && exit 1)
	@npm install -g @tobilu/qmd

dev-loop:
	@PROJECT_DIR=$${PROJECT:-$$(pwd)}; \
	SPEC_FILE=$${SPEC:-$$PROJECT_DIR/SPEC.md}; \
	~/.codex/scripts/dev-loop.sh -C "$$PROJECT_DIR" -s "$$SPEC_FILE"

skills-lint:
	@! rg -n "Task \\(|Task tool|AskUserQuestion" skills/*/SKILL.md -S >/dev/null
	@echo "Skill lint passed."
