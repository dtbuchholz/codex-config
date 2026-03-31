---
name: memory-rollup
description: >
  Review and maintain Codex CLI memory files. Prunes stale entries, extracts patterns, promotes
  cross-project learnings to global memory, and updates MEMORY.md files. Run manually or via cron.
---

# Memory Rollup

Review, prune, and consolidate Codex CLI memory files across projects and global memory.

## When This Skill Applies

- User explicitly says "/memory-rollup"
- Do NOT activate automatically — this skill requires explicit invocation

## Memory Layout

The current Codex CLI memory store lives under `~/.codex/memories/`:

- `~/.codex/memories/MEMORY.md` — searchable registry of detailed task-group memory
- `~/.codex/memories/memory_summary.md` — concise cross-project summary intended for prompt loading
- `~/.codex/memories/raw_memories.md` — raw extracted source material used to build the registry
- `~/.codex/memories/rollout_summaries/` — per-rollout summary files referenced from `MEMORY.md`

Treat `memory_summary.md` as the prompt-budgeted surface. Keep it concise. `MEMORY.md` is allowed to
be more detailed, but should still remain organized and easy to search.

## Execution

### Step 1: Discover

Inspect the current memory store:

```bash
# Current memory root
ls -la ~/.codex/memories/ 2>/dev/null

# Inventory files
find ~/.codex/memories -maxdepth 2 -type f | sort
```

Read the registry, summary, and any referenced rollout summaries needed for spot checks. Build an
inventory:

| File | Purpose | Line Count | Last Modified |
| ---- | ------- | ---------- | ------------- |

### Step 2: Audit the Registry and Summaries

Evaluate:

1. **Staleness** — Do referenced repos, files, commands, or workflow claims still match reality?
   Spot check against the current workspace when accessible:
   ```bash
   # Example checks
   ls -la /Users/dtb/rcl/replay-lab 2>/dev/null
   ls -la /Users/dtb/.codex/scripts/memory-rollup.sh 2>/dev/null
   ```
2. **Accuracy** — Do paths, script names, and status claims still match the current repo state? Spot
   check 2–3 concrete claims per major task group.
3. **Density** — Is `memory_summary.md` concise enough for prompt loading? Is `MEMORY.md` organized
   enough to search without carrying duplicate detail?
4. **Duplication** — Are the same learnings repeated across task groups when they should be promoted
   into `memory_summary.md` or a single shared section?

### Step 3: Prune and Consolidate

For the current store:

- **Remove** entries that reference deleted repos, outdated paths, or disproven claims
- **Merge** duplicate task-group learnings
- **Condense** `memory_summary.md` if it grows noisy
- **Keep** `MEMORY.md` as a searchable registry that points to rollout summaries instead of
  re-explaining them in full
- **Do not rewrite** `raw_memories.md` manually unless the maintenance flow explicitly regenerates
  it

Log proposed changes, then apply them directly. Format the log as:

```
## [Memory Area]

### Remove (stale/resolved)
- "Known bug in X" — X was fixed in commit abc123

### Condense / merge
- Merge duplicate workflow guidance across task groups A and B into one summary line

### Update
- Version 1.2 → 1.4 (confirmed in package.json)
```

Apply all changes immediately after logging them.

### Step 4: Cross-Project Pattern Extraction

After auditing all projects, look for patterns that appear across 2+ projects:

- Same debugging technique used in multiple repos
- Common architectural decisions or conventions
- Repeated tool configurations or workflow preferences
- Recurring pitfalls or gotchas

These are candidates for `memory_summary.md`.

Present candidates:

```
## Summary Candidates

### Pattern: [name]
- Seen in: [project A], [project B]
- Summary: [one line]
- Proposed destination: ~/.codex/memories/memory_summary.md
```

Apply summary changes directly after logging them.

### Step 5: Mutation Guard

If higher-priority instructions prohibit editing memory files in the current environment, do an
audit-only pass instead:

- inventory the current files
- identify stale, duplicate, or oversized areas
- verify 2–3 concrete claims against the workspace
- report the exact edits that should be made, but do not write them

### Step 6: Summary

Display a final report:

```
Memory Rollup Complete
─────────────────────
Files scanned:        ___
Rollout refs checked: ___
Entries pruned:       ___
Entries updated:      ___
Summary updates:      ___
Audit-only mode:      yes|no
Line counts:          MEMORY.md ___, memory_summary.md ___, raw_memories.md ___
```

## Rules

- Never delete a memory file entirely — prune entries, don't remove files
- Keep `memory_summary.md` concise; it is the prompt-budgeted layer
- Prefer rollout summaries for detailed notes; `MEMORY.md` should stay searchable and structured
- When unsure if something is stale, ask rather than delete
- If a referenced repo directory no longer exists on disk, flag it but don't auto-delete its memory
- Do not add new learnings during this skill — only reorganize existing ones
