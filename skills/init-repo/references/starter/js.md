# Starter JS/TS Setup

Use this for the lightest JavaScript or TypeScript scaffold. Starter mode is commands-only: no git
hooks, no CI, no monorepo assumptions.

## Create

- `package.json` with `type: "module"` for JS or TypeScript dev dependencies for TS.
- `.gitignore` covering `node_modules/`, `dist/`, `.turbo/`, `.next/`, `coverage/`, `.env*`.
- `.prettierrc` and `.prettierignore`.
- `src/` and `tests/` directories.
- TypeScript only: `tsconfig.json` with `strict: true`.

## Scripts

Use these scripts as the minimum baseline:

```json
{
  "scripts": {
    "format": "prettier --write .",
    "format:check": "prettier --check .",
    "test": "vitest run"
  }
}
```

If the project is TypeScript, add:

```json
{
  "scripts": {
    "type-check": "tsc --noEmit"
  }
}
```

## Dependencies

Use `pnpm` by default:

- JS: `prettier`, `vitest`.
- TS: `typescript`, `tsx`, `prettier`, `vitest`.

Starter intentionally does not include ESLint. If the user wants linting, hooks, or CI, use
`standard` mode.

## Verify

Run:

```bash
pnpm install
pnpm format:check
pnpm test
```

For TypeScript, also run:

```bash
pnpm type-check
```
