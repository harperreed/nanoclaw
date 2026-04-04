#!/bin/bash
# ABOUTME: Interactive shell into a group's container with the same mounts NanoClaw uses.
# ABOUTME: Usage: ./scripts/shell-group.sh [--shell] <group-folder>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Require python3 for JSON parsing (settings.json, container_config)
if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required but not found in PATH"
  exit 1
fi

# --- Arg parsing: extract --shell flag, leave positional args ---
SHELL_MODE=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=true ;;
    *) ARGS+=("$arg") ;;
  esac
done
# Bash 3.2 (macOS default) crashes on "${ARGS[@]}" when array is empty under set -u
if [ "${#ARGS[@]}" -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

# --- Safe .env parsing (no eval) ---
if [ -z "${NANOCLAW_BASE_DIR:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  NANOCLAW_BASE_DIR=$(grep '^NANOCLAW_BASE_DIR=' "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
BASE_DIR="${NANOCLAW_BASE_DIR:-$PROJECT_ROOT}"
DB="$BASE_DIR/store/messages.db"
GROUPS_DIR="$BASE_DIR/groups"
DATA_DIR="$BASE_DIR/data"

TZ=$(grep '^TZ=' "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
TZ="${TZ:-UTC}"
CREDENTIAL_PROXY_PORT=$(grep '^CREDENTIAL_PROXY_PORT=' "$PROJECT_ROOT/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)
CREDENTIAL_PROXY_PORT="${CREDENTIAL_PROXY_PORT:-7424}"

# Detect auth mode: if ANTHROPIC_API_KEY is set in .env, use api-key; otherwise oauth
if grep -q '^ANTHROPIC_API_KEY=' "$PROJECT_ROOT/.env" 2>/dev/null; then
  AUTH_MODE="api-key"
else
  AUTH_MODE="oauth"
fi

# --- Usage ---
if [ -z "${1:-}" ]; then
  echo "Usage: $0 [--shell] <group-folder>"
  echo ""
  echo "  Default: launches Claude Code interactively"
  echo "  --shell: launches /bin/bash instead"
  echo ""
  echo "Available groups:"
  sqlite3 "$DB" "SELECT '  ' || folder || ' (' || name || ')' || CASE WHEN COALESCE(is_main, 0) = 1 THEN ' [main]' ELSE '' END FROM registered_groups ORDER BY folder;"
  exit 1
fi

FOLDER="$1"

# --- Input sanitization ---
if [[ ! "$FOLDER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: invalid group folder name (alphanumeric, dash, underscore only)"
  exit 1
fi

# --- Look up group in DB ---
# Separate queries avoid pipe-in-JSON truncation (container_config is JSON and may contain |)
# Input is sanitized above to ^[a-zA-Z0-9_-]+$ so interpolation is safe.
NAME=$(sqlite3 "$DB" "SELECT name FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
if [ -z "$NAME" ]; then
  echo "Error: group '$FOLDER' not found."
  echo ""
  echo "Available groups:"
  sqlite3 "$DB" "SELECT '  ' || folder || ' (' || name || ')' || CASE WHEN COALESCE(is_main, 0) = 1 THEN ' [main]' ELSE '' END FROM registered_groups ORDER BY folder;"
  exit 1
fi
IS_MAIN=$(sqlite3 "$DB" "SELECT COALESCE(is_main, 0) FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
CONTAINER_CONFIG=$(sqlite3 "$DB" "SELECT container_config FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")

if [ "$SHELL_MODE" = true ]; then
  ENTRYPOINT="/bin/bash"
  echo "Entering container for group: $NAME ($FOLDER) [bash shell]"
else
  ENTRYPOINT="claude"
  echo "Entering container for group: $NAME ($FOLDER) [Claude Code]"
fi
if [ "$IS_MAIN" = "1" ]; then
  echo "  (main group)"
fi
echo ""

# --- Detect bridge IP (Apple Container vmnet bridge) ---
# Apple Container creates bridge100+ with a 192.168.64.x subnet.
# Same detection logic as container-runtime.ts findBridgeIp().
BRIDGE_IP=$(ifconfig 2>/dev/null | awk '
  /^bridge[0-9]+:/ { iface=1; next }
  /^[^ \t]/ { iface=0 }
  iface && /inet 192\.168\.64\./ { print $2; exit }
')
if [ -z "$BRIDGE_IP" ]; then
  echo "Warning: Could not detect Apple Container bridge IP. Credential proxy may not work."
  BRIDGE_IP="192.168.64.1"
fi

# --- Build env args ---
ENV_ARGS=()
if [ -n "$TZ" ]; then
  ENV_ARGS+=(-e "TZ=$TZ")
fi
ENV_ARGS+=(-e "ANTHROPIC_BASE_URL=http://${BRIDGE_IP}:${CREDENTIAL_PROXY_PORT}")
if [ "$AUTH_MODE" = "api-key" ]; then
  ENV_ARGS+=(-e "ANTHROPIC_API_KEY=placeholder")
else
  ENV_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=placeholder")
fi

# --- Build mount args ---
MOUNT_ARGS=()

# Group workspace
mkdir -p "$GROUPS_DIR/$FOLDER/logs"
MOUNT_ARGS+=(-v "$GROUPS_DIR/$FOLDER:/workspace/group")

# Main group: mount BASE_DIR as /workspace/project (ro) + rw store shadow
if [ "$IS_MAIN" = "1" ]; then
  MOUNT_ARGS+=(--mount "type=bind,source=$BASE_DIR,target=/workspace/project,readonly")
  MOUNT_ARGS+=(-v "$BASE_DIR/store:/workspace/project/store")
fi

# Global memory directory (non-main only, matching container-runner.ts)
if [ "$IS_MAIN" != "1" ] && [ -d "$GROUPS_DIR/global" ]; then
  MOUNT_ARGS+=(--mount "type=bind,source=$GROUPS_DIR/global,target=/workspace/global,readonly")
fi

# Claude sessions dir
SESSIONS_DIR="$DATA_DIR/sessions/$FOLDER/.claude"
mkdir -p "$SESSIONS_DIR"

# --- Settings.json creation ---
SETTINGS_FILE="$SESSIONS_DIR/settings.json"
python3 -c "
import json, os, sys

settings_file = sys.argv[1]
group_dir = sys.argv[2]

# Load existing settings or start fresh
if os.path.exists(settings_file):
    with open(settings_file) as f:
        settings = json.load(f)
else:
    settings = {}

# Set env vars (same as container-runner.ts)
settings['env'] = {
    'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS': '1',
    'CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD': '1',
    'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '0',
}

# Sync MCP servers from group's .mcp.json
mcp_json_path = os.path.join(group_dir, '.mcp.json')
if os.path.exists(mcp_json_path):
    try:
        with open(mcp_json_path) as f:
            mcp_json = json.load(f)
        if isinstance(mcp_json.get('mcpServers'), dict):
            settings['mcpServers'] = mcp_json['mcpServers']
    except Exception:
        pass

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" "$SETTINGS_FILE" "$GROUPS_DIR/$FOLDER"

# --- Skills sync ---
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

MOUNT_ARGS+=(-v "$SESSIONS_DIR:/home/node/.claude")

# Shared XDG directories
SHARED_CONFIG_DIR="$DATA_DIR/config"
HOST_LOCAL_SHARE_DIR="$HOME/.local/share"
MSGVAULT_DIR="$DATA_DIR/msgvault"
mkdir -p "$SHARED_CONFIG_DIR" "$MSGVAULT_DIR"
MOUNT_ARGS+=(-v "$SHARED_CONFIG_DIR:/home/node/.config")
MOUNT_ARGS+=(-v "$HOST_LOCAL_SHARE_DIR:/home/node/.local/share")
MOUNT_ARGS+=(-v "$MSGVAULT_DIR:/home/node/.msgvault")

# IPC dir
IPC_DIR="$DATA_DIR/ipc/$FOLDER"
mkdir -p "$IPC_DIR/messages" "$IPC_DIR/tasks" "$IPC_DIR/input"
MOUNT_ARGS+=(-v "$IPC_DIR:/workspace/ipc")

# Agent runner source (per-group writable copy, same as container-runner.ts)
AGENT_RUNNER_SRC="$PROJECT_ROOT/container/agent-runner/src"
GROUP_AGENT_RUNNER_DIR="$DATA_DIR/sessions/$FOLDER/agent-runner-src"
if [ -d "$AGENT_RUNNER_SRC" ]; then
  mkdir -p "$GROUP_AGENT_RUNNER_DIR"
  cp -R "$AGENT_RUNNER_SRC"/* "$GROUP_AGENT_RUNNER_DIR/" 2>/dev/null || true
fi
MOUNT_ARGS+=(-v "$GROUP_AGENT_RUNNER_DIR:/app/src")

# --- Additional mounts from container_config ---
if [ -n "$CONTAINER_CONFIG" ] && [ "$CONTAINER_CONFIG" != "null" ]; then
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

  while IFS='|' read -r host_path container_path ro_flag; do
    [ -z "$host_path" ] && continue
    if [ "$ro_flag" = "ro" ]; then
      MOUNT_ARGS+=(--mount "type=bind,source=$host_path,target=$container_path,readonly")
    else
      MOUNT_ARGS+=(-v "$host_path:$container_path")
    fi
  done <<< "$EXTRA_MOUNTS"
fi

# --- Container naming ---
TIMESTAMP=$(date +%s)
SAFE_NAME=$(echo "$FOLDER" | tr -cd 'a-zA-Z0-9_-')
CONTAINER_NAME="nanoclaw-shell-${SAFE_NAME}-${TIMESTAMP}"

WORKDIR="/workspace/group"

# --- Print summary ---
echo "Container: $CONTAINER_NAME"
echo "Bridge IP: $BRIDGE_IP"
echo "Auth mode: $AUTH_MODE"
echo ""
echo "Mounts:"
for arg in "${MOUNT_ARGS[@]}"; do
  [[ "$arg" == *"/workspace"* || "$arg" == *"/home/node"* ]] && echo "  $arg"
done
echo ""
echo "Working directory: $WORKDIR"
if [ "$SHELL_MODE" = true ]; then
  echo "Press Ctrl+D or type 'exit' to leave."
else
  echo "Press Ctrl+C or type /exit to leave Claude Code."
fi
echo ""

container run -it --rm \
  --name "$CONTAINER_NAME" \
  "${ENV_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  -w "$WORKDIR" \
  --entrypoint "$ENTRYPOINT" \
  nanoclaw-agent:latest
