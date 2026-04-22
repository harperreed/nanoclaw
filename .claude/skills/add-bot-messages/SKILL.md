---
name: add-bot-messages
description: Store all outgoing agent messages in the SQLite DB with is_bot_message=1. Enables full conversation thread querying so agents can see their own historical responses. Triggers on "bot messages", "store outgoing", "conversation history", "agent responses", "backfill messages".
---

# Add Bot Message Storage

Stores all outgoing agent messages in the SQLite DB with `is_bot_message=1`. Before this feature, only incoming user messages were stored — agents could not see their own previous responses when querying conversation history. This enables full thread reconstruction.

## Prerequisites

- NanoClaw with SQLite DB at `$NANOCLAW_BASE_DIR/store/messages.db`
- The `messages` table must have an `is_bot_message` column (added in migration)

## Phase 1: Add `genBotMsgId()` Helper

Add to `src/index.ts` (near the top, after imports):

```typescript
/** Generate a unique ID for outgoing bot messages. */
function genBotMsgId(): string {
  return `bot-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}
```

IDs are prefixed with `bot-` to distinguish them from channel message IDs.

## Phase 2: Add `storeBotOutgoing()` Helper

Add to `src/index.ts`, immediately after `genBotMsgId()`:

```typescript
/** Store an outgoing bot message in the DB so agents can query full threads. */
function storeBotOutgoing(
  chatJid: string,
  content: string,
  senderName: string,
): void {
  storeMessageDirect({
    id: genBotMsgId(),
    chat_jid: chatJid,
    sender: 'bot',
    sender_name: senderName,
    content,
    timestamp: new Date().toISOString(),
    is_from_me: true,
    is_bot_message: true,
  });
}
```

This uses `storeMessageDirect()` from `src/db.ts` which inserts directly into the `messages` table.

### Field Values

| Field | Value | Why |
|-------|-------|-----|
| `id` | `bot-{timestamp}-{random}` | Unique, distinguishable from channel IDs |
| `sender` | `'bot'` | Consistent sender identity for queries |
| `sender_name` | Group name (e.g., `'pa'`, `'main'`) | Identifies which agent sent it |
| `is_from_me` | `true` | Marks as outgoing |
| `is_bot_message` | `true` | Enables filtering bot vs. user messages |

## Phase 3: Call After Every Send

Call `storeBotOutgoing()` after every `channel.sendMessage()` call in `src/index.ts`. This includes:

1. **Agent responses** — after the streaming output callback sends the final message
2. **IPC messages** — after forwarding inter-group messages
3. **File sends** — after `channel.sendFile()` with the caption as content

Example from the streaming output callback:

```typescript
await channel.sendMessage(chatJid, text);
storeBotOutgoing(chatJid, text, group.name);
```

## Phase 4: Backfill Historical Messages

For existing installations, create `scripts/backfill-bot-messages.ts` to import historical agent responses from Claude SDK JSONL logs.

### What the Backfill Does

1. Opens `$NANOCLAW_BASE_DIR/store/messages.db`
2. Loads the group folder-to-JID mapping from `registered_groups`
3. Scans `data/sessions/<folder>/.claude/projects/-workspace-group/*.jsonl`
4. Extracts assistant text messages from JSONL entries with `"type":"assistant"`
5. Strips `<internal>...</internal>` tags (these are never sent to users)
6. Inserts with `INSERT OR IGNORE` to avoid duplicates
7. Uses `bot-backfill-{timestamp}-{random}` IDs

### Running the Backfill

```bash
cd $NANOCLAW_BASE_DIR
npx tsx /path/to/nanoclaw/scripts/backfill-bot-messages.ts
```

Example output:

```
  main (Main Group): 142 messages backfilled
  pa (Personal Assistant): 87 messages backfilled
  research (Research): 23 messages backfilled

Done: 252 inserted, 0 skipped (duplicates)
```

### JSONL Parsing

The backfill extracts text from assistant message content blocks:

```typescript
const d = JSON.parse(line);
if (d.type !== 'assistant') continue;
const content = d.message?.content;
if (!Array.isArray(content)) continue;

const textParts: string[] = [];
for (const block of content) {
  if (block.type === 'text' && block.text) {
    textParts.push(block.text);
  }
}
```

## Verify

```bash
npm run build
```

After restarting and sending a message, check the DB:

```bash
sqlite3 $NANOCLAW_BASE_DIR/store/messages.db \
  "SELECT id, sender, sender_name, substr(content, 1, 50) FROM messages WHERE is_bot_message = 1 ORDER BY timestamp DESC LIMIT 5;"
```

Expected: rows with `sender='bot'` and the agent's group name as `sender_name`.

After running the backfill:

```bash
sqlite3 $NANOCLAW_BASE_DIR/store/messages.db \
  "SELECT COUNT(*) FROM messages WHERE is_bot_message = 1;"
```

## Architecture

```
Agent produces output
  -> Orchestrator sends via channel.sendMessage()
  -> storeBotOutgoing() writes to SQLite
     {id: 'bot-...', sender: 'bot', is_bot_message: 1}
  -> Next agent run can query full thread (user + bot messages)

Backfill (one-time):
  data/sessions/<folder>/.claude/projects/-workspace-group/*.jsonl
  -> Parse assistant messages
  -> Strip <internal> tags
  -> INSERT OR IGNORE into messages table
```

### What Does NOT Change

- Container/agent-runner — no changes inside containers
- Message format — `storeMessageDirect()` uses the existing schema
- Incoming message handling — only outgoing messages are affected
- Query patterns — existing queries still work; bot messages are additive

## Removal

Remove from `src/index.ts`:
- `genBotMsgId()` function
- `storeBotOutgoing()` function
- All `storeBotOutgoing()` call sites

Remove the backfill script:
```bash
rm scripts/backfill-bot-messages.ts
```

Optionally clean up backfilled data:
```bash
sqlite3 $NANOCLAW_BASE_DIR/store/messages.db \
  "DELETE FROM messages WHERE is_bot_message = 1;"
```

## Troubleshooting

- **"no such column: is_bot_message"** — Run the DB migration to add the column: `ALTER TABLE messages ADD COLUMN is_bot_message INTEGER DEFAULT 0;`
- **Backfill finds no JSONL files** — Check that session dirs exist at `data/sessions/<folder>/.claude/projects/-workspace-group/`. The path uses `-workspace-group` (dashes, not slashes) because Claude SDK hashes the project path.
- **Duplicate messages after re-running backfill** — The script uses `INSERT OR IGNORE`, so re-runs are safe. Duplicates are skipped.
- **Bot messages not appearing in agent context** — Verify the agent's message query includes `is_bot_message` rows. The default `getRecentMessages()` should return all messages regardless of source.
- **Empty content after backfill** — Messages that were entirely `<internal>` tags are skipped. This is intentional — those messages were never sent to users.
