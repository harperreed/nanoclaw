# Intent: src/config.ts modifications

## What changed
Added `NANOCLAW_BASE_DIR` environment variable support so data directories
(store, groups, data) can live in a separate location from the source code.

## Why
The default NanoClaw layout puts everything in the project root. This
installation separates data from code: source lives in the git repo,
while runtime data (SQLite DB, group folders, agent sessions) lives
elsewhere (e.g., /Users/harper/Public/agent/).

## Key sections

### BASE_DIR export
- Added: `export const BASE_DIR` that reads `NANOCLAW_BASE_DIR` env var
- Falls back to `PROJECT_ROOT` (process.cwd()) when env var is not set
- Must appear after `PROJECT_ROOT` declaration, before path definitions

### Path definitions
- Changed: `STORE_DIR`, `GROUPS_DIR`, `DATA_DIR` resolve from `BASE_DIR` instead of `PROJECT_ROOT`
- This is the core change — all data paths follow `BASE_DIR`

## Invariants
- `PROJECT_ROOT` still exists and still equals `process.cwd()` (used by container-runner for source mounts)
- All other exports (ASSISTANT_NAME, TRIGGER_PATTERN, TIMEZONE, etc.) are unchanged
- `BASE_DIR` defaults to `PROJECT_ROOT` when `NANOCLAW_BASE_DIR` is not set, so behavior is identical for default installations

## Must-keep
- The `BASE_DIR` export — it is imported by `container-runner.ts`
- `STORE_DIR`, `GROUPS_DIR`, `DATA_DIR` must use `BASE_DIR`, not `PROJECT_ROOT`
