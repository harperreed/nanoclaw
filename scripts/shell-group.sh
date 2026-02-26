#!/bin/bash
# ABOUTME: Interactive shell into a group's container with the same mounts NanoClaw uses.
# ABOUTME: Usage: ./scripts/shell-group.sh <group-folder>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env for NANOCLAW_BASE_DIR if not already set
if [ -z "${NANOCLAW_BASE_DIR:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  eval "$(grep '^NANOCLAW_BASE_DIR=' "$PROJECT_ROOT/.env")"
fi
BASE_DIR="${NANOCLAW_BASE_DIR:-$PROJECT_ROOT}"
DB="$BASE_DIR/store/messages.db"
GROUPS_DIR="$BASE_DIR/groups"
DATA_DIR="$BASE_DIR/data"

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <group-folder>"
  echo ""
  echo "Available groups:"
  sqlite3 "$DB" "SELECT '  ' || folder || ' (' || name || ')' FROM registered_groups ORDER BY folder;"
  exit 1
fi

FOLDER="$1"

# Look up group in DB
ROW=$(sqlite3 "$DB" "SELECT name, folder, container_config FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
if [ -z "$ROW" ]; then
  echo "Error: group '$FOLDER' not found."
  echo ""
  echo "Available groups:"
  sqlite3 "$DB" "SELECT '  ' || folder || ' (' || name || ')' FROM registered_groups ORDER BY folder;"
  exit 1
fi

NAME=$(echo "$ROW" | cut -d'|' -f1)
CONTAINER_CONFIG=$(echo "$ROW" | cut -d'|' -f3)

echo "Entering container for group: $NAME ($FOLDER)"
echo ""

# Build mount args
MOUNT_ARGS=()

# Group workspace
mkdir -p "$GROUPS_DIR/$FOLDER/logs"
MOUNT_ARGS+=(-v "$GROUPS_DIR/$FOLDER:/workspace/group")

# Claude sessions dir
SESSIONS_DIR="$DATA_DIR/sessions/$FOLDER/.claude"
mkdir -p "$SESSIONS_DIR"
MOUNT_ARGS+=(-v "$SESSIONS_DIR:/home/node/.claude")

# Shared XDG directories (toki, chronicle, memo, bbs, etc.)
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

# Global memory directory
if [ -d "$GROUPS_DIR/global" ]; then
  MOUNT_ARGS+=(-v "$GROUPS_DIR/global:/workspace/global:ro")
fi

# Agent runner source
MOUNT_ARGS+=(--mount "type=bind,source=$PROJECT_ROOT/container/agent-runner/src,target=/app/src,readonly")

# For main group: also mount data directory (BASE_DIR) read-only
if [ "$FOLDER" = "main" ]; then
  MOUNT_ARGS+=(-v "$BASE_DIR:/workspace/project:ro")
fi

WORKDIR="/workspace/group"

echo "Mounts:"
for arg in "${MOUNT_ARGS[@]}"; do
  [[ "$arg" == *"/workspace"* || "$arg" == *"/home/node"* ]] && echo "  $arg"
done
echo ""
echo "Working directory: $WORKDIR"
echo "Press Ctrl+D or type 'exit' to leave."
echo ""

container run -it --rm \
  "${MOUNT_ARGS[@]}" \
  -w "$WORKDIR" \
  --entrypoint /bin/bash \
  nanoclaw-agent:latest
