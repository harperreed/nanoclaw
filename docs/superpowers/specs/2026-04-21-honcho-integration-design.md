# Honcho Integration — Design Spec

## Goal

Integrate Honcho (cloud, v3 API) as a reasoning-based memory layer for all NanoClaw agents. Each group's agent builds a persistent model of Harper across sessions. Honcho complements existing memory (Chronicle, soul.md, conversations/) — it doesn't replace them.

## Architecture

Single new module `src/honcho.ts` handles all Honcho interactions. Host-side only — nothing inside containers.

### Honcho Data Model Mapping

| Honcho Concept | NanoClaw Equivalent |
|---|---|
| Workspace | "nanoclaw" (single instance) |
| User Peer | "harper" (Doctor Biz) |
| AI Peer | One per group folder (e.g., "pa", "main", "research") |
| Session | Maps to NanoClaw group session (reused within conversation) |
| Messages | User messages + bot responses synced after each turn |

### Module: `src/honcho.ts`

**Exports:**
- `initHoncho()` — Called on startup. Creates workspace, user peer. Returns boolean (enabled or not).
- `getHonchoContext(groupFolder: string)` — Returns a string to prepend to the agent prompt. Contains user representation + session summary. Returns empty string if Honcho unavailable.
- `syncHonchoMessages(groupFolder: string, userMessages: Array<{content: string, sender: string}>, botResponse: string)` — Pushes messages to Honcho session. Fire-and-forget (non-blocking).
- `getOrCreateHonchoSession(groupFolder: string)` — Internal. Maps group folder to Honcho session, creating AI peer + session on first use. Caches peer/session IDs in memory.

**Caching:**
- Workspace ID: cached once on init
- User peer ID: cached once on init
- AI peer IDs: cached per group folder (Map<string, string>)
- Session IDs: cached per group folder (Map<string, string>)
- Context: cached per group folder with TTL (refresh every N turns, not every turn — save API calls)

**Context format** (prepended to prompt):
```
<honcho-context>
[Honcho memory — what you know about Harper from past sessions]
{user representation text}

[Session context — what's happened recently]
{session summary text}
</honcho-context>
```

### Integration Points

**`src/index.ts` — processGroupMessages():**
```typescript
// Before building prompt:
const honchoContext = await getHonchoContext(group.folder);
// Prepend to prompt if non-empty

// After agent responds:
syncHonchoMessages(group.folder, missedMessages, outputText);
```

**`src/index.ts` — scheduled task output:**
```typescript
// After task output sent:
syncHonchoMessages(group.folder, [{content: task.prompt, sender: 'system'}], outputText);
```

**`src/config.ts`:**
```typescript
export const HONCHO_API_KEY = process.env.HONCHO_API_KEY || envConfig.HONCHO_API_KEY;
```

### What Does NOT Change

- Container/agent-runner — no Honcho SDK inside containers
- MCP tools — Honcho is host-side only
- Existing memory — Chronicle, soul.md, conversations/, BBS all remain
- Container mounts — no new mounts needed

### Failure Handling

- All Honcho calls wrapped in try/catch
- If `HONCHO_API_KEY` not set, `initHoncho()` returns false and all other functions no-op
- If Honcho API is down, `getHonchoContext()` returns empty string, `syncHonchoMessages()` logs warning and continues
- Agents always work — Honcho is additive, never blocking

### Config

- `HONCHO_API_KEY` in `.env` (already added)
- `HONCHO_WORKSPACE_ID` defaults to "nanoclaw" (no config needed)
- Context refresh cadence: every 3 turns per group (not every turn — reduces API calls)

## Testing

- Unit tests for `src/honcho.ts` with mocked HTTP client
- Verify graceful degradation when API key missing
- Verify graceful degradation when API returns errors
- Integration test: init → sync messages → get context → verify context contains user info
