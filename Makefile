SHELL := /bin/bash

.PHONY: help setup deps hooks-install hooks-verify gitleaks-install

help:
	@echo "Available targets:"
	@echo "  make setup             Install dependencies and Husky hooks"
	@echo "  make deps              Install Node dependencies with pnpm"
	@echo "  make hooks-install     Install/reinstall Husky git hooks"
	@echo "  make hooks-verify      Verify expected hook files exist"
	@echo "  make gitleaks-install  Install gitleaks via Homebrew (macOS)"

setup: deps hooks-install

deps:
	@pnpm install

hooks-install:
	@pnpm run prepare

hooks-verify:
	@test -f .husky/pre-commit || (echo "Missing .husky/pre-commit" && exit 1)
	@test -f .husky/pre-push || (echo "Missing .husky/pre-push" && exit 1)
	@echo "Husky hooks are present."

gitleaks-install:
	@command -v brew >/dev/null 2>&1 || (echo "Homebrew not found. Install gitleaks manually." && exit 1)
	@brew install gitleaks
