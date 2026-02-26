#!/bin/bash
# ABOUTME: Show scheduled tasks queue with status, schedule, and group info.
# ABOUTME: Usage: ./scripts/tasks.sh (or npm run tasks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env for NANOCLAW_BASE_DIR if not already set
if [ -z "${NANOCLAW_BASE_DIR:-}" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  eval "$(grep '^NANOCLAW_BASE_DIR=' "$PROJECT_ROOT/.env")"
fi
BASE_DIR="${NANOCLAW_BASE_DIR:-$PROJECT_ROOT}"
DB="$BASE_DIR/store/messages.db"

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[90m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

NOW=$(date +%s)

format_relative() {
  local iso="$1"
  [ -z "$iso" ] && echo "-" && return
  # Convert ISO to epoch
  local epoch
  epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%%.*}" +%s 2>/dev/null || echo "0")
  [ "$epoch" = "0" ] && echo "$iso" && return

  local diff=$((epoch - NOW))
  if [ "$diff" -lt 0 ]; then
    diff=$((-diff))
    local label="ago"
  else
    local label=""
  fi

  if [ "$diff" -lt 60 ]; then
    echo "just now"
  elif [ "$diff" -lt 3600 ]; then
    echo "$((diff / 60))m ${label}"
  elif [ "$diff" -lt 86400 ]; then
    echo "$((diff / 3600))h ${label}"
  else
    echo "$((diff / 86400))d ${label}"
  fi
}

format_schedule() {
  local type="$1"
  local value="$2"
  if [ "$type" = "cron" ]; then
    echo "$value"
  elif [ "$type" = "interval" ]; then
    local ms=$((value))
    local secs=$((ms / 1000))
    if [ "$secs" -lt 60 ]; then
      echo "every ${secs}s"
    elif [ "$secs" -lt 3600 ]; then
      echo "every $((secs / 60))m"
    else
      echo "every $((secs / 3600))h"
    fi
  elif [ "$type" = "once" ]; then
    echo "once"
  else
    echo "$type"
  fi
}

status_color() {
  case "$1" in
    active)    echo -e "${GREEN}active${RESET}" ;;
    paused)    echo -e "${YELLOW}paused${RESET}" ;;
    completed) echo -e "${DIM}done${RESET}" ;;
    *)         echo -e "${RED}$1${RESET}" ;;
  esac
}

# Terminal width for truncation
TERM_WIDTH=$(tput cols 2>/dev/null || echo 120)
PROMPT_WIDTH=$((TERM_WIDTH - 75))
[ "$PROMPT_WIDTH" -lt 15 ] && PROMPT_WIDTH=15

# Count by status
active_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM scheduled_tasks WHERE status = 'active';")
paused_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM scheduled_tasks WHERE status = 'paused';")
completed_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM scheduled_tasks WHERE status = 'completed';")
total_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM scheduled_tasks;")

# Active tasks header
echo -e "${BOLD}$(printf '%-14s %-10s %-18s %-8s %-8s %s' 'GROUP' 'STATUS' 'SCHEDULE' 'NEXT' 'LAST' 'PROMPT')${RESET}"
echo "──────────────  ──────────  ──────────────────  ────────  ────────  ──────────────────────"

# Query active and paused tasks first, then completed
sqlite3 -separator '|' "$DB" "
  SELECT
    st.group_folder,
    rg.name,
    st.status,
    st.schedule_type,
    st.schedule_value,
    st.next_run,
    st.last_run,
    REPLACE(REPLACE(substr(st.prompt, 1, 200), CHAR(10), ' '), CHAR(13), '')
  FROM scheduled_tasks st
  LEFT JOIN registered_groups rg ON rg.folder = st.group_folder
  WHERE st.status IN ('active', 'paused')
  ORDER BY
    CASE st.status WHEN 'active' THEN 0 WHEN 'paused' THEN 1 ELSE 2 END,
    st.group_folder,
    st.schedule_value;
" | while IFS='|' read -r folder name status sched_type sched_value next_run last_run prompt; do
  [ -z "$folder" ] && continue

  display="${name:-$folder}"
  if [ ${#display} -gt 13 ]; then
    display="${display:0:12}…"
  fi

  colored_status=$(status_color "$status")
  schedule=$(format_schedule "$sched_type" "$sched_value")
  if [ ${#schedule} -gt 17 ]; then
    schedule="${schedule:0:16}…"
  fi

  next=$(format_relative "$next_run")
  last=$(format_relative "$last_run")

  # Truncate prompt
  prompt=$(echo "$prompt" | sed 's/  */ /g')
  if [ ${#prompt} -gt "$PROMPT_WIDTH" ]; then
    prompt="${prompt:0:$((PROMPT_WIDTH - 1))}…"
  fi

  echo -e "$(printf '%-14s' "$display") $(printf '%-21s' "$colored_status") $(printf '%-18s' "$schedule") $(printf '%-8s' "$next") $(printf '%-8s' "$last")  ${DIM}${prompt}${RESET}"
done

# Summary
echo ""
echo -e "${GREEN}${active_count} active${RESET}, ${YELLOW}${paused_count} paused${RESET}, ${DIM}${completed_count} completed${RESET}, ${total_count} total"

# Recent runs
echo ""
echo -e "${BOLD}Recent Runs${RESET}"
echo "──────────────  ──────────  ────────  ──────────────────────"
echo -e "${BOLD}$(printf '%-14s %-10s %-8s %s' 'GROUP' 'STATUS' 'WHEN' 'DURATION')${RESET}"

sqlite3 -separator '|' "$DB" "
  SELECT
    st.group_folder,
    rg.name,
    l.status,
    l.run_at,
    l.duration_ms
  FROM task_run_logs l
  JOIN scheduled_tasks st ON l.task_id = st.id
  LEFT JOIN registered_groups rg ON rg.folder = st.group_folder
  ORDER BY l.run_at DESC
  LIMIT 10;
" | while IFS='|' read -r folder name status run_at duration_ms; do
  [ -z "$folder" ] && continue

  display="${name:-$folder}"
  if [ ${#display} -gt 13 ]; then
    display="${display:0:12}…"
  fi

  if [ "$status" = "success" ]; then
    colored_status="${GREEN}ok${RESET}"
  else
    colored_status="${RED}fail${RESET}"
  fi

  when=$(format_relative "$run_at")

  # Format duration
  if [ "$duration_ms" -lt 1000 ]; then
    dur="${duration_ms}ms"
  elif [ "$duration_ms" -lt 60000 ]; then
    dur="$((duration_ms / 1000))s"
  else
    dur="$((duration_ms / 60000))m$((duration_ms % 60000 / 1000))s"
  fi

  echo -e "$(printf '%-14s' "$display") $(printf '%-21s' "$colored_status") $(printf '%-8s' "$when") ${dur}"
done
