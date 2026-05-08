---
name: configure-harper-mounts
description: Use when setting up Harper's custom per-group filesystem mounts, mount allowlist, and shared Obsidian access. Triggers on "harper mounts", "group mounts", "mount config", "additional mounts", "allowlist".
---

# Configure Harper's Group Mounts

Configures per-group `additionalMounts` and the mount allowlist for Harper's NanoClaw installation. Each group gets tailored host filesystem access.

## When to Use

- Fresh NanoClaw install needs Harper's mount layout
- Adding a new group that needs host filesystem access
- Modifying mount permissions or allowlist

## Prerequisites

- NanoClaw v2 installed, groups created
- `~/.config/nanoclaw/mount-allowlist.json` exists

## Step 1: Mount Allowlist

Edit `~/.config/nanoclaw/mount-allowlist.json`:

```json
{
  "allowedPaths": [
    "/Users/harper/agentspace",
    "/Users/harper/Public",
    "/Users/harper/.msgvault",
    "/Users/harper/.config/gsuite-mcp",
    "/Users/harper/.local/share/gsuite-mcp",
    "/Users/harper/Dropbox/Documents/Personal/finances"
  ],
  "blockedPatterns": [],
  "unblockedPatterns": [],
  "nonMainReadOnly": false
}

```

`nonMainReadOnly: false` allows read-write for non-main groups. To unblock default-blocked patterns (e.g. `.ssh`), add them to `unblockedPatterns`.

## Step 2: Per-Group Mounts

For each group, add `containerConfig.additionalMounts` to the group config. Format:

```json
{
  "containerConfig": {
    "additionalMounts": [
      { "hostPath": "/absolute/host/path", "containerPath": "name", "readOnly": true }
    ]
  }
}
```

Mounts appear at `/workspace/extra/<containerPath>` inside the container.

### Mount Map

| Group | containerPath | hostPath | readOnly |
|-------|--------------|----------|----------|
| thinktank | worldview | `/Users/harper/agentspace/worldview` | true |
| thinktank | current-events | `/Users/harper/agentspace/current-events` | true |
| current-events | worldview | `/Users/harper/agentspace/worldview` | true |
| current-events | thinktank | `/Users/harper/agentspace/thinktank` | true |
| pa | pa | `/Users/harper/Public/AgentWorkspace/pa` | false |
| pa | .msgvault | `/Users/harper/.msgvault` | false |
| pa | .config-gsuite-mcp | `/Users/harper/.config/gsuite-mcp` | true |
| pa | .local-share-gsuite-mcp | `/Users/harper/.local/share/gsuite-mcp` | true |
| health | healthdata | `/Users/harper/Public/src/personal/healthdata` | true |
| 2389 | personal-os | `/Users/harper/Public/agent/groups/personal-os` | true |
| finances | finances | `/Users/harper/Dropbox/Documents/Personal/finances` | false |
| finances | .msgvault | `/Users/harper/.msgvault` | false |

### Global Mount (all groups)

Every group gets the Obsidian vault:

| containerPath | hostPath | readOnly |
|--------------|----------|----------|
| HarperObsidian | `/Users/harper/Public/Harper Notes` | false |

## Step 3: Secrets

If any group needs `TWITTER_API_KEY`, add it to the secrets allowlist in `src/container-runner.ts` inside the `readSecrets()` function's key array.

## Step 4: Verify

1. Restart NanoClaw
2. Send a test message to a group with mounts
3. Check container logs for mount registration
4. Inside container, verify `/workspace/extra/*` paths exist with correct permissions

## Implementation Notes

- `buildVolumeMounts` in `src/container-runner.ts` deduplicates by `fs.realpathSync` to avoid Apple Container VirtioFS tag collisions
- Validation uses `validateAdditionalMounts()` in `src/mount-security.ts`
- Allowlist file is never mounted into containers
