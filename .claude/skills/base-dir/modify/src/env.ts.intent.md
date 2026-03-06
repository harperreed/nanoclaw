# Intent: src/env.ts modifications

## What changed
The .env file path now respects `NANOCLAW_BASE_DIR` instead of always
reading from `process.cwd()`.

## Why
When data is separated from code via `NANOCLAW_BASE_DIR`, the .env file
lives with the data, not the source. env.ts must compute BASE_DIR inline
(not import it from config.ts) because config.ts imports env.ts — a
circular import would break module loading.

## Key sections

### readEnvFile path computation
- Changed: `path.join(process.cwd(), '.env')` to inline `NANOCLAW_BASE_DIR` resolution
- The inline computation mirrors config.ts: check env var, fallback to cwd()

## Invariants
- Function signature unchanged: `readEnvFile(keys: string[]): Record<string, string>`
- Parsing logic unchanged (line splitting, quote stripping, key filtering)
- Must NOT import from config.ts (circular dependency)

## Must-keep
- The inline `NANOCLAW_BASE_DIR` resolution — cannot be extracted to config.ts
- The comment explaining why it's inline
