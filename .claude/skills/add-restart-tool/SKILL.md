---
name: add-restart-tool
description: Add a restart_nanoclaw MCP tool that agents can call to safely restart the orchestrator. Uses clean process.exit(0) so launchd restarts the service. Triggers on "restart tool", "restart nanoclaw", "agent restart", "host access", "restart mcp".
---

# Add Restart NanoClaw Tool

Adds a `restart_nanoclaw` MCP tool that agents can call to safely restart the NanoClaw orchestrator. Uses `process.exit(0)` so launchd (macOS) or systemd (Linux) restarts the service cleanly — no SSH, no SIGTERM races.

## Prerequisites

- NanoClaw with the MCP server (`container/agent-runner/src/ipc-mcp-stdio.ts`)
- IPC watcher running (`src/ipc.ts`)
- Service managed by launchd or systemd (so `exit(0)` triggers a restart)

## Phase 1: Add `hostAccess` to ContainerConfig

In `src/types.ts`, add the `hostAccess` flag to the `ContainerConfig` interface:

```typescript
export interface ContainerConfig {
  additionalMounts?: AdditionalMount[];
  timeout?: number; // Default: 300000 (5 minutes)
  hostAccess?: boolean; // Grants ssh_localhost and restart_nanoclaw tools (always true for isMain)
}
```

This flag grants host-level tools to non-main groups. Main groups always have host access.

## Phase 2: Plumb the Environment Variable

The `hostAccess` flag must flow from the DB config through to the container:

1. **`src/container-runner.ts`** (or equivalent container launch code): Read `containerConfig.hostAccess` and set `NANOCLAW_HOST_ACCESS=1` in the container's environment when the group is main or has `hostAccess: true`.

2. **`container/agent-runner/src/ipc-mcp-stdio.ts`**: Read the env var at startup:

```typescript
const hasHostAccess = process.env.NANOCLAW_HOST_ACCESS === '1';
```

## Phase 3: Add the MCP Tool

In `container/agent-runner/src/ipc-mcp-stdio.ts`, register the `restart_nanoclaw` tool:

```typescript
server.tool(
  'restart_nanoclaw',
  'Safely restart the NanoClaw orchestrator service. Requires host access privilege (isMain or containerConfig.hostAccess). The service will restart cleanly via launchd after a 2-second delay. Use this instead of shelling out to launchctl.',
  {},
  async () => {
    if (!hasHostAccess) {
      return {
        content: [
          {
            type: 'text' as const,
            text: 'Error: restart_nanoclaw requires host access privilege.',
          },
        ],
        isError: true,
      };
    }

    writeIpcFile(TASKS_DIR, {
      type: 'restart_nanoclaw',
      chatJid,
      groupFolder,
      timestamp: new Date().toISOString(),
    });

    return {
      content: [
        {
          type: 'text' as const,
          text: 'Restart requested. NanoClaw will restart in ~2 seconds.',
        },
      ],
    };
  },
);
```

The tool takes no arguments. It writes an IPC task file and returns immediately — the agent gets a confirmation before the restart happens.

## Phase 4: Add the IPC Handler

In `src/ipc.ts`, inside the `processTaskIpc()` switch statement, add the `restart_nanoclaw` case:

```typescript
case 'restart_nanoclaw':
  // Safe restart: uses process.exit so launchd restarts us cleanly.
  // No SSH, no SIGTERM race conditions.
  if (!hasHostAccess) {
    logger.warn(
      { sourceGroup },
      'Unauthorized restart_nanoclaw attempt blocked',
    );
    break;
  }
  logger.info({ sourceGroup }, 'Restart requested via IPC, exiting in 2s');
  if (data.chatJid) {
    try {
      await deps.sendMessage(data.chatJid, 'Restarting NanoClaw...');
    } catch {
      // Best effort notification
    }
  }
  setTimeout(() => process.exit(0), 2000);
  break;
```

### Critical Design Details

1. **File deleted BEFORE processing**: The IPC watcher deletes the task file before calling `processTaskIpc()`. This prevents restart loops — if the file were still present after `process.exit(0)`, it would be re-executed on boot.

   ```typescript
   // In the IPC watcher loop (already implemented):
   fs.unlinkSync(filePath);  // Delete FIRST
   await processTaskIpc(data, sourceGroup, isMain, hasHostAccess, deps);
   ```

2. **2-second delay**: `setTimeout(() => process.exit(0), 2000)` gives the orchestrator time to:
   - Send the "Restarting NanoClaw..." notification
   - Flush logs
   - Complete any in-flight IPC processing

3. **Best-effort notification**: The chat message is wrapped in try/catch — if sending fails, the restart still happens.

4. **Authorization check**: The IPC handler checks `hasHostAccess` independently of the MCP tool's check. This is defense-in-depth — even if a container's env var is spoofed, the host-side check uses the DB-verified privilege map.

## Phase 5: Host Access Privilege Map

In `src/ipc.ts`, the privilege is computed from the registered groups DB:

```typescript
const folderHasHostAccess = new Map<string, boolean>();
for (const group of Object.values(registeredGroups)) {
  if (group.isMain || group.containerConfig?.hostAccess) {
    folderHasHostAccess.set(group.folder, true);
  }
}
```

This means:
- Main groups always have host access
- Non-main groups need `containerConfig.hostAccess: true` in the DB
- The privilege is checked on the host side (tamper-proof from containers)

## Phase 6: Grant Host Access to a Group

To grant `hostAccess` to a non-main group, update its `container_config` in the DB:

```bash
sqlite3 $NANOCLAW_BASE_DIR/store/messages.db \
  "UPDATE registered_groups SET container_config = json_set(COALESCE(container_config, '{}'), '$.hostAccess', json('true')) WHERE folder = 'pa';"
```

Or via the main group's `register_group` IPC with `containerConfig: { hostAccess: true }`.

## Verify

```bash
npm run build
npm test
```

Restart the service:

```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # macOS
```

Test from an agent with host access:
1. Send a message asking the agent to restart NanoClaw
2. The agent calls `restart_nanoclaw` MCP tool
3. You should see "Restarting NanoClaw..." in chat
4. The service restarts within ~2 seconds
5. Check logs: `grep "Restart requested" logs/nanoclaw.log`

Test from an agent without host access:
1. The tool should return an error: "requires host access privilege"
2. Check logs: `grep "Unauthorized restart_nanoclaw" logs/nanoclaw.log`

## Architecture

```
Agent calls restart_nanoclaw MCP tool
  -> Tool checks NANOCLAW_HOST_ACCESS env var
  -> Writes IPC task file: { type: 'restart_nanoclaw', chatJid, groupFolder }
  -> Returns "Restart requested" to agent

Host IPC watcher polls tasks dir
  -> Reads and DELETES task file (prevents restart loop)
  -> processTaskIpc() checks hasHostAccess from DB
  -> Sends "Restarting NanoClaw..." to chat (best-effort)
  -> setTimeout(() => process.exit(0), 2000)
  -> launchd/systemd detects exit and restarts the service
```

### Security Layers

| Layer | Check | Purpose |
|-------|-------|---------|
| MCP tool | `NANOCLAW_HOST_ACCESS` env var | Prevents tool from appearing functional to unauthorized agents |
| IPC handler | `hasHostAccess` from DB privilege map | Defense-in-depth against env var spoofing |
| File deletion | `fs.unlinkSync` before processing | Prevents restart loops |

### What Does NOT Change

- The container image — no new binaries or scripts
- Other MCP tools — restart is an independent tool
- launchd/systemd config — relies on existing service restart behavior
- Channel connections — they reconnect on the new process boot

## Removal

1. Remove the `restart_nanoclaw` tool from `container/agent-runner/src/ipc-mcp-stdio.ts`
2. Remove the `restart_nanoclaw` case from `src/ipc.ts` `processTaskIpc()`
3. Optionally remove `hostAccess` from `ContainerConfig` in `src/types.ts` (only if no other tools use it)
4. Remove `NANOCLAW_HOST_ACCESS` env var from container launch code

```bash
npm run build
```

## Troubleshooting

- **"requires host access privilege"** — The group doesn't have `hostAccess: true` in its `container_config` and is not the main group. Update the DB or use the main group.
- **Restart doesn't happen** — Check that the IPC watcher is running and the tasks dir exists at `$DATA_DIR/ipc/<folder>/tasks/`. Check logs for "Restart requested via IPC".
- **Service doesn't come back after restart** — Verify launchd/systemd is configured to restart on exit. Check: `launchctl print gui/$(id -u)/com.nanoclaw` (macOS) or `systemctl --user status nanoclaw` (Linux).
- **"Unauthorized restart_nanoclaw attempt blocked"** — A container without host access tried to restart. This is the host-side defense-in-depth check working correctly.
- **Restart loop** — Should not happen because the IPC file is deleted before processing. If it does, check that `fs.unlinkSync(filePath)` is called before `processTaskIpc()` in the IPC watcher loop.
