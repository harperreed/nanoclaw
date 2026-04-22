---
name: add-honcho
description: Add Honcho cloud memory integration to NanoClaw. Provides reasoning-based cross-session user modeling — agents build a persistent understanding of the user across conversations. Triggers on "add honcho", "honcho", "memory integration", "cross-session memory".
---

# Add Honcho Memory Integration

Integrates [Honcho](https://honcho.dev) (cloud v3 API) as a reasoning-based memory layer. Each agent group gets its own AI peer; the user is a shared peer. Honcho builds a persistent model of the user from conversations, injecting cross-session context into agent prompts.

Honcho is **additive** — all calls are wrapped in try/catch with timeouts. If Honcho is down, agents work normally. Existing memory systems (Chronicle, soul.md, conversations/) are unaffected.

## Prerequisites

- A Honcho API key from [app.honcho.dev](https://app.honcho.dev)
- NanoClaw with WhatsApp (or other channel) already configured

## Phase 1: Install SDK

```bash
npm install @honcho-ai/sdk
```

Verify:
```bash
npm ls @honcho-ai/sdk
```

## Phase 2: Add API Key

Add to the `.env` file in `NANOCLAW_BASE_DIR` (NOT the source code `.env`):

```bash
echo "HONCHO_API_KEY=<your-key>" >> "$NANOCLAW_BASE_DIR/.env"
```

The key is read via `readEnvFile()` at runtime — it's never exported as a module constant and never mounted into containers.

## Phase 3: Create `src/honcho.ts`

Create `src/honcho.ts` with these exports:

```typescript
export async function initHoncho(): Promise<boolean>
export async function getHonchoContext(groupFolder: string): Promise<string>
export function syncHonchoMessages(
  groupFolder: string,
  userMessages: Array<{ content: string; sender: string }>,
  botResponse: string,
  isScheduledTask?: boolean,
): void
```

### `initHoncho()`

- Read `HONCHO_API_KEY` from process.env OR `readEnvFile(['HONCHO_API_KEY'])` from `./env.js`
- If no key, log info and return false
- Create `Honcho` client with `{ apiKey, workspaceId: 'nanoclaw' }`
- Warm cache: `await honcho.peer('harper')`
- 10s timeout via AbortController. Return false on failure.

### `getHonchoContext(groupFolder)`

- If not initialized, return `''`
- Get or create AI peer: `honcho.peer(groupFolder)` (cached in Map)
- Get or create session: `honcho.session(groupFolder)` (cached in Map)
- On new session: `session.addPeers([harperPeer, aiPeer])`
- Call `harperPeer.representation()` for cross-session user model
- 2s timeout via AbortController
- Cache with hybrid TTL: refresh after 3 turns OR 2 hours
- Return formatted XML or `''` on error:

```xml
<honcho-context>
[External memory — cross-session context about the user]
{representation text}
</honcho-context>
```

### `syncHonchoMessages()`

- If not initialized or `isScheduledTask`, return immediately
- Map user messages via `harperPeer.message(content)`
- Map bot response via `aiPeer.message(botResponse)`
- Call `session.addMessages(messages)`
- **Fire-and-forget**: `.catch(err => logger.warn(...))`
- Increment turn counter for cache TTL

## Phase 4: Integrate into `src/index.ts`

### Startup (in `main()`)

After `restoreRemoteControl()`, before channel setup:

```typescript
import { getHonchoContext, initHoncho, syncHonchoMessages } from './honcho.js';

// In main():
await initHoncho();
```

### Before agent prompt (in `processGroupMessages()`)

After the trigger check, before `formatMessages()`:

```typescript
const honchoContext = await getHonchoContext(group.folder);
const rawPrompt = formatMessages(missedMessages, TIMEZONE);
const prompt = honchoContext ? `${honchoContext}\n\n${rawPrompt}` : rawPrompt;
```

### After agent response (in streaming output callback)

After `storeBotOutgoing()`:

```typescript
syncHonchoMessages(
  group.folder,
  missedMessages.map(m => ({ content: m.content, sender: m.sender_name })),
  text,
);
```

## Phase 5: Integrate into `src/task-scheduler.ts`

In the task output callback, after `deps.sendMessage()`:

```typescript
import { syncHonchoMessages } from './honcho.js';

syncHonchoMessages(
  task.group_folder,
  [{ content: task.prompt, sender: 'system' }],
  streamedOutput.result,
  true, // isScheduledTask — skipped by Honcho sync
);
```

The `isScheduledTask: true` flag causes `syncHonchoMessages()` to return immediately, preventing automated task noise from polluting the user model.

## Phase 6: Verify

```bash
npm run build
npm test
```

Restart the service:

```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
```

Check logs for successful initialization:

```bash
grep -i honcho logs/nanoclaw.log
```

Expected: `Honcho initialized`

Send a message to any agent group. Check logs for:
- `Honcho context retrieval` (on first message — may be empty until Honcho has data)
- No `Honcho sync failed` errors

## Architecture

```
User message arrives
  → getHonchoContext(groupFolder)     [2s timeout, cached]
  → Prepend to agent prompt
  → Agent runs in container
  → Agent responds
  → storeBotOutgoing() to DB
  → syncHonchoMessages()              [fire-and-forget, .catch(log)]
```

### Honcho Data Model

| Honcho Concept | NanoClaw Mapping |
|---|---|
| Workspace | `nanoclaw` (single instance) |
| User Peer | `harper` (shared across all groups) |
| AI Peer | One per group folder (e.g., `pa`, `main`, `research`) |
| Session | One per group folder (long-lived, cached) |
| Messages | Attributed to peers via `peer.message(content)` |

### What Does NOT Change

- Container/agent-runner — no Honcho SDK inside containers
- MCP tools — Honcho is host-side only
- Existing memory — Chronicle, soul.md, conversations/, BBS, memo all remain
- Container mounts — no new mounts

### Failure Handling

- All calls in try/catch with timeouts (2s context, 10s init)
- `syncHonchoMessages()` is fire-and-forget with `.catch(log)`
- If API key missing: `initHoncho()` returns false, all other functions no-op
- If API down: `getHonchoContext()` returns `''`, sync logs warning
- Agents always work — Honcho is additive, never blocking

## Removal

```bash
# Remove the module
rm src/honcho.ts

# Remove imports and calls from src/index.ts:
#   - import line for honcho.js
#   - await initHoncho() in main()
#   - getHonchoContext() call and prompt prepend
#   - syncHonchoMessages() call in output callback

# Remove import and call from src/task-scheduler.ts

# Remove the dependency
npm uninstall @honcho-ai/sdk

# Remove the API key
# Edit $NANOCLAW_BASE_DIR/.env and remove the HONCHO_API_KEY line

npm run build
```

## Troubleshooting

- **"Honcho: no API key found"** — Key must be in `$NANOCLAW_BASE_DIR/.env`, not the source code `.env`. Check with `grep HONCHO_API_KEY "$NANOCLAW_BASE_DIR/.env"`.
- **"Honcho initialization failed"** — API key may be invalid or Honcho API may be down. Check `api.honcho.dev` status.
- **"Honcho context retrieval failed"** — Transient API error. Context will be retried on the next cache miss. Agents continue without Honcho context.
- **"Honcho sync failed"** — Message sync failed (fire-and-forget). Messages are not retried. Check API key and network.
- **Empty context for a long time** — Honcho needs several conversations to build a user representation. The first few interactions will return empty context.
