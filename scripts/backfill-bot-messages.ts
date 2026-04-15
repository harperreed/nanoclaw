// ABOUTME: One-shot script to backfill outgoing bot messages from Claude SDK JSONL logs.
// ABOUTME: Reads agent conversation transcripts and inserts assistant text as is_bot_message=1.

import fs from 'fs';
import path from 'path';
import readline from 'readline';
import Database from 'better-sqlite3';

const STORE_DB = path.resolve('store/messages.db');
const SESSIONS_DIR = path.resolve('data/sessions');

// Map group folders to their JIDs and display names from the DB
function loadGroupMap(db: Database.Database): Record<string, { jid: string; name: string }> {
  const rows = db.prepare('SELECT jid, name, folder FROM registered_groups').all() as Array<{
    jid: string;
    name: string;
    folder: string;
  }>;
  const map: Record<string, { jid: string; name: string }> = {};
  for (const row of rows) {
    map[row.folder] = { jid: row.jid, name: row.name };
  }
  return map;
}

interface AssistantMessage {
  text: string;
  timestamp: string;
}

// Extract assistant text messages from a JSONL file
async function extractAssistantMessages(filePath: string): Promise<AssistantMessage[]> {
  const messages: AssistantMessage[] = [];
  const stream = fs.createReadStream(filePath, { encoding: 'utf-8' });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

  for await (const line of rl) {
    if (!line.includes('"type":"assistant"')) continue;
    try {
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
      if (textParts.length === 0) continue;

      const text = textParts.join('\n').trim();
      // Skip internal-only messages
      const stripped = text.replace(/<internal>[\s\S]*?<\/internal>/g, '').trim();
      if (!stripped) continue;

      messages.push({
        text: stripped,
        timestamp: d.timestamp || new Date().toISOString(),
      });
    } catch {
      // Skip malformed lines
    }
  }

  return messages;
}

async function main() {
  if (!fs.existsSync(STORE_DB)) {
    console.error('Database not found:', STORE_DB);
    process.exit(1);
  }

  const db = new Database(STORE_DB);
  const groupMap = loadGroupMap(db);

  const insert = db.prepare(
    `INSERT OR IGNORE INTO messages (id, chat_jid, sender, sender_name, content, timestamp, is_from_me, is_bot_message)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  );

  let totalInserted = 0;
  let totalSkipped = 0;

  const sessionDirs = fs.readdirSync(SESSIONS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name);

  for (const folder of sessionDirs) {
    const group = groupMap[folder];
    if (!group) {
      console.log(`  ${folder}: no registered group, skipping`);
      continue;
    }

    const jsonlDir = path.join(SESSIONS_DIR, folder, '.claude/projects/-workspace-group');
    if (!fs.existsSync(jsonlDir)) {
      console.log(`  ${folder}: no JSONL dir, skipping`);
      continue;
    }

    const jsonlFiles = fs.readdirSync(jsonlDir)
      .filter((f) => f.endsWith('.jsonl'))
      .map((f) => path.join(jsonlDir, f));

    let folderInserted = 0;

    for (const file of jsonlFiles) {
      const messages = await extractAssistantMessages(file);

      for (const msg of messages) {
        const id = `bot-backfill-${new Date(msg.timestamp).getTime()}-${Math.random().toString(36).slice(2, 8)}`;
        const result = insert.run(
          id,
          group.jid,
          'bot',
          group.name,
          msg.text,
          msg.timestamp,
          1,
          1,
        );
        if (result.changes > 0) {
          folderInserted++;
          totalInserted++;
        } else {
          totalSkipped++;
        }
      }
    }

    console.log(`  ${folder} (${group.name}): ${folderInserted} messages backfilled`);
  }

  db.close();
  console.log(`\nDone: ${totalInserted} inserted, ${totalSkipped} skipped (duplicates)`);
}

main().catch((err) => {
  console.error('Backfill failed:', err);
  process.exit(1);
});
