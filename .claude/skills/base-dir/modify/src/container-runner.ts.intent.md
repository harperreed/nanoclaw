# Intent: src/container-runner.ts modifications

## What changed
The main group's read-only mount uses `BASE_DIR` instead of `projectRoot`
(process.cwd()). This mounts the data directory into the container, not
the source code directory.

## Key sections

### Import
- Added: `BASE_DIR` to the import from `./config.js`

### buildVolumeMounts — main mount
- Changed: `hostPath: projectRoot` to `hostPath: BASE_DIR`
- Changed: comment from "project root" to "data directory"
- The container path remains `/workspace/project` (unchanged)

## Invariants
- `projectRoot` (process.cwd()) is still used for .env shadow mount path computation
- All other mounts are unchanged
- The function signature is unchanged

## Must-keep
- `BASE_DIR` import from config.ts
- `hostPath: BASE_DIR` on the main read-only mount
