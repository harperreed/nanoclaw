---
name: add-shell-group
description: Add interactive container shell script for dropping into any group's agent container. Provides full mount parity with the production runner. Triggers on "shell group", "interactive container", "shell into group", "debug container", "container shell".
---

# Add Interactive Container Shell

Adds `scripts/shell-group.sh` — a script that drops users into any group's agent container with Claude Code (default) or bash (`--shell` flag). The container gets the same mounts, env vars, and skills as the production agent runner, making it ideal for debugging and interactive development.

## Prerequisites

- NanoClaw installed with a working SQLite DB at `$NANOCLAW_BASE_DIR/store/messages.db`
- At least one registered group in the DB
- Apple Container runtime running (the script uses `container run`)
- `python3` available on PATH (used for JSON parsing)

## Phase 1: Create the Script

Create `scripts/shell-group.sh` in the NanoClaw source directory. The script must be executable.

```bash
chmod +x scripts/shell-group.sh
```

### Usage

```bash
# Launch Claude Code interactively in a group's container
./scripts/shell-group.sh <group-folder>

# Launch bash shell instead
./scripts/shell-group.sh --shell <group-folder>

# Show usage and available groups
./scripts/shell-group.sh
```

## Phase 2: Input Sanitization

The script reads group config from SQLite via `sqlite3` CLI. To prevent SQL injection, validate the folder name before any DB queries:

```bash
FOLDER="$1"

# --- Input sanitization ---
if [[ ! "$FOLDER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: invalid group folder name (alphanumeric, dash, underscore only)"
  exit 1
fi
```

Only after this check does the script interpolate `$FOLDER` into SQL queries. The regex restricts input to `[a-zA-Z0-9_-]+`.

## Phase 3: Group Lookup from DB

The script runs separate `sqlite3` queries to avoid pipe-in-JSON truncation (container_config is JSON and may contain `|`):

```bash
NAME=$(sqlite3 "$DB" "SELECT name FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
IS_MAIN=$(sqlite3 "$DB" "SELECT COALESCE(is_main, 0) FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
CONTAINER_CONFIG=$(sqlite3 "$DB" "SELECT container_config FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
```

If no group is found, the script lists available groups and exits.

## Phase 4: Environment Variables

The script sets up credential proxy env vars so the container can make API calls through the host proxy:

```bash
ENV_ARGS+=(-e "TZ=$TZ")
ENV_ARGS+=(-e "ANTHROPIC_BASE_URL=http://${BRIDGE_IP}:${CREDENTIAL_PROXY_PORT}")
if [ "$AUTH_MODE" = "api-key" ]; then
  ENV_ARGS+=(-e "ANTHROPIC_API_KEY=placeholder")
else
  ENV_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=placeholder")
fi
```

The placeholder values are replaced by the credential proxy — containers never see real tokens.

## Phase 5: Bridge IP Detection

For Apple Container, the script detects the vmnet bridge IP (same logic as `container-runtime.ts findBridgeIp()`):

```bash
BRIDGE_IP=$(ifconfig 2>/dev/null | awk '
  /^bridge[0-9]+:/ { iface=1; next }
  /^[^ \t]/ { iface=0 }
  iface && /inet 192\.168\.64\./ { print $2; exit }
')
if [ -z "$BRIDGE_IP" ]; then
  echo "Warning: Could not detect Apple Container bridge IP. Credential proxy may not work."
  BRIDGE_IP="192.168.64.1"
fi
```

## Phase 6: Mount Parity

The script builds the same mounts as the production `container-runner.ts`:

| Mount | Container Path | Notes |
|-------|---------------|-------|
| Group workspace | `/workspace/group` | read-write |
| Global memory | `/workspace/global` | read-only, non-main only |
| Project source | `/workspace/project` | read-only, main only |
| Claude sessions | `/home/node/.claude` | read-write, includes skills |
| IPC directory | `/workspace/ipc` | read-write |
| Agent runner src | `/app/src` | per-group writable copy |
| Additional mounts | `/workspace/extra/{path}` | from `container_config.additionalMounts` |

Additional mounts are parsed from the group's `container_config` JSON using `python3`:

```bash
EXTRA_MOUNTS=$(python3 -c "
import json, os, sys

config = json.loads(sys.argv[1])
mounts = config.get('additionalMounts', [])
for m in mounts:
    host_path = os.path.expanduser(m.get('hostPath', ''))
    container_path = m.get('containerPath', '')
    readonly = m.get('readonly', True)
    if host_path and container_path and os.path.exists(host_path):
        ro_flag = 'ro' if readonly else 'rw'
        print(f'{host_path}|/workspace/extra/{container_path}|{ro_flag}')
" "$CONTAINER_CONFIG" 2>/dev/null || true)
```

## Phase 7: Skills Sync and Settings

Before launching, the script syncs global skills from `container/skills/` into the session's `.claude/skills/` directory and creates a `settings.json` with the same env vars the production runner uses:

```bash
SKILLS_SRC="$PROJECT_ROOT/container/skills"
SKILLS_DST="$SESSIONS_DIR/skills"
if [ -d "$SKILLS_SRC" ]; then
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    mkdir -p "$SKILLS_DST/$skill_name"
    cp -R "$skill_dir"* "$SKILLS_DST/$skill_name/" 2>/dev/null || true
  done
fi
```

Settings include `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and MCP server config from the group's `.mcp.json`.

## Phase 8: Container Naming

Containers are named for easy identification in `container list`:

```bash
TIMESTAMP=$(date +%s)
SAFE_NAME=$(echo "$FOLDER" | tr -cd 'a-zA-Z0-9_-')
CONTAINER_NAME="nanoclaw-shell-${SAFE_NAME}-${TIMESTAMP}"
```

## Phase 9: Launch

```bash
container run -it --rm \
  --name "$CONTAINER_NAME" \
  "${ENV_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  -w "$WORKDIR" \
  --entrypoint "$ENTRYPOINT" \
  nanoclaw-agent:latest
```

The `--rm` flag auto-removes the container on exit. Working directory is `/workspace/group`.

## Verify

```bash
# List available groups
./scripts/shell-group.sh

# Enter a group's container with Claude Code
./scripts/shell-group.sh main

# Enter a group's container with bash
./scripts/shell-group.sh --shell main

# Verify mounts are correct inside the container
ls /workspace/group /workspace/ipc /home/node/.claude
```

## Architecture

```
User runs ./scripts/shell-group.sh [--shell] <folder>
  -> Validates folder name (regex)
  -> Queries SQLite for group config
  -> Detects bridge IP for credential proxy
  -> Builds env vars (TZ, auth mode, proxy URL)
  -> Builds mount args (same as container-runner.ts)
  -> Syncs skills, creates settings.json
  -> container run -it --rm ... nanoclaw-agent:latest
```

### What Does NOT Change

- The production `container-runner.ts` — this script is independent
- The credential proxy — the shell container uses the same proxy
- Group config in the DB — read-only access
- Container image — uses the same `nanoclaw-agent:latest`

## Removal

```bash
rm scripts/shell-group.sh
```

No other files are affected.

## Troubleshooting

- **"python3 is required but not found"** — Install Python 3. The script uses it to parse JSON (container_config, settings.json).
- **"invalid group folder name"** — Folder names must match `^[a-zA-Z0-9_-]+$`. Check `sqlite3 $DB "SELECT folder FROM registered_groups;"`.
- **"Could not detect Apple Container bridge IP"** — The Apple Container vmnet bridge isn't up. Start the container runtime first: `container system start`.
- **"Credential proxy may not work"** — The bridge IP defaults to `192.168.64.1` but may differ. Check `ifconfig` for `bridge100+` interfaces with `192.168.64.x`.
- **Container exits immediately** — Check that `nanoclaw-agent:latest` image exists: `container image list`.
- **MCP servers not available** — Ensure the group's `.mcp.json` exists in `$GROUPS_DIR/$FOLDER/` and is valid JSON.
