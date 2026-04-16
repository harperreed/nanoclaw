# NanoClaw

Personal Claude assistant. See [README.md](README.md) for philosophy and setup. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) for architecture decisions.

## Quick Context

Single Node.js process that connects to WhatsApp, routes messages to Claude Agent SDK running in containers (Linux VMs). Each group has isolated filesystem and memory.

## Key Files

| File | Purpose |
|------|---------|
| `src/index.ts` | Orchestrator: state, message loop, agent invocation |
| `src/channels/whatsapp.ts` | WhatsApp connection, auth, send/receive |
| `src/ipc.ts` | IPC watcher and task processing |
| `src/router.ts` | Message formatting and outbound routing |
| `src/config.ts` | Trigger pattern, paths, intervals |
| `src/container-runner.ts` | Spawns agent containers with mounts |
| `src/task-scheduler.ts` | Runs scheduled tasks |
| `src/db.ts` | SQLite operations |
| `groups/{name}/CLAUDE.md` | Per-group memory (isolated) |
| `container/skills/agent-browser.md` | Browser automation tool (available to all agents via Bash) |

## Skills

| Skill | When to Use |
|-------|-------------|
| `/setup` | First-time installation, authentication, service configuration |
| `/customize` | Adding channels, integrations, changing behavior |
| `/debug` | Container issues, logs, troubleshooting |
| `/update` | Pull upstream NanoClaw changes, merge with customizations, run migrations |
| `/qodo-pr-resolver` | Fetch and fix Qodo PR review issues interactively or in batch |
| `/get-qodo-rules` | Load org- and repo-level coding rules from Qodo before code tasks |

## Container Mount Paths

Every agent container gets a standard set of mounts. Groups can also have additional mounts configured via `containerConfig.additionalMounts`.

### Standard Mounts (all groups)

| Container Path | Host Path | Mode |
|---------------|-----------|------|
| `/workspace/group` | `GROUPS_DIR/{folder}` | read-write |
| `/workspace/global` | `GROUPS_DIR/global` | read-write |
| `/workspace/project` | `BASE_DIR` (NanoClaw source) | read-only |
| `/workspace/ipc` | `DATA_DIR/ipc/{folder}` | read-write |

### Additional Mounts (per-group)

Configured in `containerConfig.additionalMounts`. Mounted at `/workspace/extra/{containerPath}`.

| Group | Container Path | Host Path | Mode |
|-------|---------------|-----------|------|
| thinktank | `/workspace/extra/worldview` | `/Users/harper/agentspace/worldview` | read-only |
| thinktank | `/workspace/extra/current-events` | `/Users/harper/agentspace/current-events` | read-only |
| current-events | `/workspace/extra/worldview` | `/Users/harper/agentspace/worldview` | read-only |
| current-events | `/workspace/extra/thinktank` | `/Users/harper/agentspace/thinktank` | read-only |
| pa | `/workspace/extra/pa` | `/Users/harper/Public/AgentWorkspace/pa` | read-write |
| pa | `/workspace/extra/.msgvault` | `/Users/harper/.msgvault` | read-write |
| pa | `/workspace/extra/.config-gsuite-mcp` | `/Users/harper/.config/gsuite-mcp` | read-only |
| pa | `/workspace/extra/.local-share-gsuite-mcp` | `/Users/harper/.local/share/gsuite-mcp` | read-only |
| health | `/workspace/extra/healthdata` | `/Users/harper/Public/src/personal/healthdata` | read-only |
| 2389 | `/workspace/extra/personal-os` | `/Users/harper/Public/agent/groups/personal-os` | read-only |
| finances | `/workspace/extra/finances` | `/Users/harper/Dropbox/Documents/Personal/finances` | read-write |
| finances | `/workspace/extra/.msgvault` | `/Users/harper/.msgvault` | read-write |
| all groups | `/workspace/extra/HarperObsidian` | `/Users/harper/Public/Harper Notes` | read-write |

Mount security is controlled by `~/.config/nanoclaw/mount-allowlist.json` (never mounted into containers).

## Development

Run commands directly—don't tell the user to run them.

```bash
npm run dev          # Run with hot reload
npm run build        # Compile TypeScript
./container/build.sh # Rebuild agent container
```

Service management:
```bash
# macOS (launchd)
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # restart

# Linux (systemd)
systemctl --user start nanoclaw
systemctl --user stop nanoclaw
systemctl --user restart nanoclaw
```

## Container Build Cache

The container buildkit caches the build context aggressively. `--no-cache` alone does NOT invalidate COPY steps — the builder's volume retains stale files. To force a truly clean rebuild, prune the builder then re-run `./container/build.sh`.
