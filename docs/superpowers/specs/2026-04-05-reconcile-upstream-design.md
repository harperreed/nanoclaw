# Reconcile Upstream — Design Spec

## Goal

A standalone bash script (`scripts/reconcile-upstream.sh`) that safely reconciles a NanoClaw fork with upstream changes. Auto-applies safe upstream-only changes, protects local customizations, never touches secrets, and presents conflicts for manual review.

## Problem

NanoClaw forks diverge from upstream over time. The existing `/update` skill handles small incremental updates but breaks on deep divergence because it can't distinguish "your customization" from "upstream code you merged in earlier." Manual rebasing creates massive conflicts when merge-style update commits (e.g., "update nanoclaw from 1.2.X to 1.2.Y") collide with upstream's own history.

## Architecture

Single bash script, no Node/TS dependencies. Uses git, sqlite3 is NOT needed. Relies on `git diff`, `git merge-base`, and `git checkout` for file-level operations.

### Flow

```
fetch upstream
  → find merge-base(main, upstream/main)
  → classify all changed files into 4 buckets
  → create reconcile branch
  → auto-apply upstream-only changes
  → skip secrets/sensitive files
  → generate report of conflicts
  → commit auto-applied changes
  → print summary + next steps
```

### File Classification

For each file that differs between `main` and `upstream/main`:

1. **Diff file against merge-base from both sides:**
   - `upstream_changed` = file differs between merge-base and upstream/main
   - `local_changed` = file differs between merge-base and main (local)

2. **Classify:**
   - `upstream_changed && !local_changed` → **UPSTREAM_ONLY** (safe to auto-apply)
   - `!upstream_changed && local_changed` → **LOCAL_ONLY** (keep, no action)
   - `upstream_changed && local_changed` → **BOTH_CHANGED** (conflict, needs review)
   - File in secrets blocklist → **SENSITIVE** (always skip, regardless of changes)

### Secrets Blocklist

Files matching any of these patterns are NEVER modified, even if upstream changed them:

```
.env
.env.*
*.pem
*.key
*.p12
*secret*
*credential*
*token*
mount-allowlist.json
sender-allowlist.json
```

The blocklist is hardcoded in the script. When a sensitive file is skipped, print a warning so the user knows upstream has changes they may want to review manually.

### Branch Strategy

All changes go on a new branch `reconcile-YYYY-MM-DD` created from current `main`. Never modifies `main` directly. The user can review, test, and merge at their leisure.

### Report Output

The script generates `reconcile-report.md` in the repo root (gitignored) with:

```markdown
# Upstream Reconciliation Report — YYYY-MM-DD

## Summary
- Upstream version: X.Y.Z
- Local version: X.Y.Z
- Files auto-applied: N
- Files kept (local only): N
- Files needing review: N
- Sensitive files skipped: N

## Auto-Applied (upstream only)
- path/to/file.ts — description of upstream change

## Kept (local only)
- path/to/file.ts

## Needs Review (both changed)
- path/to/file.ts
  - Upstream: [commit messages]
  - Local: [summary of your changes]

## Sensitive (skipped)
- .env — upstream has changes, review manually
```

### Confirmation Gate

Before applying any changes, the script prints:
- How many files will be auto-applied
- How many conflicts exist
- How many sensitive files are skipped

Then asks: "Proceed? [y/N]"

### Error Handling

- If `upstream` remote doesn't exist, print setup instructions and exit
- If working tree is dirty, warn and exit (require clean state)
- If no changes found, print "already up to date" and exit

## Interface

```bash
# Basic usage — fetches upstream, classifies, applies safe changes
./scripts/reconcile-upstream.sh

# Dry run — classify and report only, don't apply anything
./scripts/reconcile-upstream.sh --dry-run

# Show what upstream changed in a specific file
./scripts/reconcile-upstream.sh --show <file>
```

## What This Does NOT Do

- Auto-merge "both changed" files (too risky, always manual)
- Resolve merge conflicts (that's the user's job after reviewing the report)
- Touch secrets or sensitive config (never, even if upstream changed them)
- Modify main directly (always creates a branch)
- Replace the /update skill (complementary — /update handles version-bumped releases, this handles deep divergence)

## Testing

- Run with `--dry-run` on current fork state to verify classification is correct
- Verify secrets blocklist catches `.env` and config files
- Verify auto-applied files match upstream exactly
- Verify "both changed" files are NOT modified
