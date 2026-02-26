#!/bin/bash
# ABOUTME: Show running and idle agent status, like htop for NanoClaw.
# ABOUTME: Usage: ./scripts/ps.sh (or npm run ps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env for NANOCLAW_BASE_DIR if not already set
if [ -z "${NANOCLAW_BASE_DIR:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  eval "$(grep '^NANOCLAW_BASE_DIR=' "$PROJECT_ROOT/.env")"
fi
BASE_DIR="${NANOCLAW_BASE_DIR:-$PROJECT_ROOT}"
DB="$BASE_DIR/store/messages.db"
DATA_DIR="$BASE_DIR/data"

NOW=$(date +%s)

# Colors
GREEN='\033[32m'
DIM='\033[90m'
BOLD='\033[1m'
RESET='\033[0m'

# Get running nanoclaw containers into an associative array
declare -A RUNNING_CONTAINERS
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  # Strip "nanoclaw-" prefix and trailing "-<timestamp>"
  group=$(echo "$name" | sed 's/^nanoclaw-//' | sed 's/-[0-9]*$//')
  RUNNING_CONTAINERS["$group"]="$name"
done < <(container list 2>/dev/null | grep '^nanoclaw-' | grep -v buildkit || true)

# Pre-fetch last messages for all groups in one query
# Output: folder|sender_name|is_from_me|content (truncated, newlines stripped)
declare -A LAST_MESSAGES
while IFS='|' read -r folder sender is_bot content; do
  [ -z "$folder" ] && continue
  # Clean up: strip newlines, truncate
  content=$(echo "$content" | tr '\n' ' ' | sed 's/  */ /g')
  if [ ${#content} -gt 50 ]; then
    content="${content:0:50}…"
  fi
  if [ "$is_bot" = "1" ]; then
    LAST_MESSAGES["$folder"]="${DIM}→ ${content}${RESET}"
  else
    LAST_MESSAGES["$folder"]="${sender}: ${content}"
  fi
done < <(sqlite3 "$DB" "
  SELECT rg.folder,
         COALESCE(m.sender_name, 'Unknown'),
         m.is_bot_message,
         REPLACE(REPLACE(m.content, CHAR(10), ' '), CHAR(13), '')
  FROM registered_groups rg
  LEFT JOIN messages m ON m.chat_jid = rg.jid
    AND m.timestamp = (SELECT MAX(m2.timestamp) FROM messages m2 WHERE m2.chat_jid = rg.jid)
  ORDER BY rg.folder;
")

format_duration() {
  local secs=$1
  if [ "$secs" -lt 5 ]; then
    echo "just now"
  elif [ "$secs" -lt 60 ]; then
    echo "${secs}s ago"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))m ago"
  elif [ "$secs" -lt 86400 ]; then
    echo "$((secs / 3600))h ago"
  else
    echo "$((secs / 86400))d ago"
  fi
}

format_uptime() {
  local secs=$1
  if [ "$secs" -lt 60 ]; then
    echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then
    echo "$((secs / 60))m"
  else
    echo "$((secs / 3600))h$((secs % 3600 / 60))m"
  fi
}

# Terminal width for truncation
TERM_WIDTH=$(tput cols 2>/dev/null || echo 120)
MSG_WIDTH=$((TERM_WIDTH - 62))
[ "$MSG_WIDTH" -lt 20 ] && MSG_WIDTH=20

# Header
echo -e "${BOLD}$(printf '%-18s %-9s %-8s %-12s %s' 'GROUP' 'STATE' 'UPTIME' 'ACTIVITY' 'LAST MESSAGE')${RESET}"
echo "────────────────  ─────────  ────────  ──────────  ────────────────────"

running_count=0
total_count=0

# Get all registered groups from DB
while IFS='|' read -r folder name; do
  [ -z "$folder" ] && continue
  total_count=$((total_count + 1))

  container_name="${RUNNING_CONTAINERS[$folder]:-}"

  if [ -n "$container_name" ]; then
    state="${GREEN}running${RESET}"
    running_count=$((running_count + 1))
    ts=$(echo "$container_name" | grep -oE '[0-9]+$')
    if [ -n "$ts" ]; then
      start_epoch=$((ts / 1000))
      uptime_secs=$((NOW - start_epoch))
      uptime=$(format_uptime $uptime_secs)
    else
      uptime="?"
    fi
  else
    state="${DIM}idle${RESET}"
    uptime="-"
  fi

  # Last IPC activity
  last_activity="-"
  msg_dir="$DATA_DIR/ipc/$folder/messages"
  if [ -d "$msg_dir" ]; then
    dir_mtime=$(stat -f %m "$msg_dir" 2>/dev/null || echo "0")
    if [ "$dir_mtime" -gt 0 ]; then
      age=$((NOW - dir_mtime))
      last_activity=$(format_duration $age)
    fi
  fi

  # Display name
  if [ "$name" != "$folder" ]; then
    display="${name}"
  else
    display="${folder}"
  fi

  last_msg="${LAST_MESSAGES[$folder]:-${DIM}-${RESET}}"

  echo -e "$(printf '%-18s' "$display") $(printf '%-20s' "$state") $(printf '%-8s' "$uptime")  $(printf '%-10s' "$last_activity")  ${last_msg}"
done < <(sqlite3 "$DB" "SELECT folder, name FROM registered_groups ORDER BY folder;")

idle_count=$((total_count - running_count))
echo ""
echo -e "${GREEN}${running_count} running${RESET}, ${idle_count} idle, ${total_count} total"
