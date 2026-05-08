---
name: add-qmd
description: Use when adding QMD conversation search engine to NanoClaw. Triggers on "qmd", "conversation search", "message search", "search history", "semantic search conversations".
---

# Add QMD Integration

Integrates [QMD](https://www.npmjs.com/package/@tobilu/qmd) — a conversation search engine with lexical and semantic search — into NanoClaw containers. Agents get MCP tools and CLI access to search conversation history and documentation.

## When to Use

- Agents need to search past conversations
- Setting up semantic/lexical search over message history
- QMD server is running on the host

## Prerequisites

- QMD server running on host at port 8182 (`npx qmd serve --port 8182`)
- NanoClaw container builds working

## Step 1: Dockerfile

In `container/Dockerfile`, add `@tobilu/qmd` to the global npm install line:

```dockerfile
RUN npm install -g agent-browser @anthropic-ai/claude-code @tobilu/qmd
```

## Step 2: Agent Runner Config

In `container/agent-runner/src/index.ts`:

**Add to `allowedTools`:**
```typescript
'mcp__qmd__*',
```

**Add to `mcpServers` config:**
```typescript
qmd: {
  type: 'http',
  url: 'http://host.docker.internal:8182/mcp',
},
```

## Step 3: Container Skill

Create `container/skills/qmd/SKILL.md`:

```markdown
---
name: qmd
description: Use when searching past conversations, messages, or documentation via QMD.
---

# QMD — Conversation Search

## MCP Tools

- `mcp__qmd__query` — search with lex (keyword), vec (semantic), or hyde (hypothetical document) modes
- `mcp__qmd__get` — get a specific document by ID
- `mcp__qmd__multi_get` — get multiple documents by ID
- `mcp__qmd__status` — check QMD server status and collection info

## Example Query

Use `mcp__qmd__query` with:
- `search_type`: `lex` (keyword), `vec` (semantic), or `hyde` (best for questions)
- `query`: your search text
- `collection`: scope to a specific collection (optional)
- `limit`: max results (default 10)

## CLI Fallback

If MCP tools are unavailable:
- `npx qmd search "keyword"` — lexical search
- `npx qmd vsearch "semantic query"` — vector search
- `npx qmd query "question"` — hyde search

## Direct File Fallback

Grep conversation files directly:
`grep -r "keyword" /workspace/group/conversations/`
```

## Step 4: Rebuild and Restart

```bash
./container/build.sh
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
```

## Step 5: Verify

Send a message like: "search our past conversations for discussions about deployment"

The agent should use `mcp__qmd__query` with `search_type: hyde`.

## Troubleshooting

- **MCP connection refused** — Ensure QMD server is running on host port 8182
- **Empty results** — QMD needs indexed data; run `npx qmd index` on your conversation directory
- **Agent uses grep instead of MCP** — Container skill may not have synced; check `container/skills/qmd/SKILL.md` exists
