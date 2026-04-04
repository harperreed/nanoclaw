# Interactive Container Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance `scripts/shell-group.sh` to launch Claude Code directly inside a group's container with full mount parity (additional mounts, credential proxy, TZ, skills sync).

**Architecture:** Enhance the existing shell script to: (1) parse `container_config` JSON from the DB for additional mounts, (2) read `is_main` from DB instead of hardcoding, (3) set up credential proxy env vars so Claude can call the API, (4) sync skills, (5) default to launching `claude` instead of bash (with `--shell` flag for bash).

**Tech Stack:** Bash, sqlite3 CLI, Apple Container (`container` binary)

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `scripts/shell-group.sh` | Modify | Interactive container shell — enhanced with claude launch, additional mounts, env vars |

Single file change. All logic stays in the shell script.

---

### Task 1: Add `--shell` flag and default to launching Claude Code

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Add flag parsing and update entrypoint**

Replace the hardcoded `--entrypoint /bin/bash` with conditional logic. Default entrypoint is `claude`, `--shell` flag switches to `bash`.

Add after the `set -euo pipefail` line:

```bash
SHELL_MODE=false
for arg in "$@"; do
  case "$arg" in
    --shell) SHELL_MODE=true; shift ;;
  esac
done
```

Update the `container run` at the bottom:

```bash
if [ "$SHELL_MODE" = true ]; then
  ENTRYPOINT="/bin/bash"
  echo "Launching bash shell..."
else
  ENTRYPOINT="claude"
  echo "Launching Claude Code..."
fi

container run -it --rm \
  "${MOUNT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -w "$WORKDIR" \
  --entrypoint "$ENTRYPOINT" \
  nanoclaw-agent:latest
```

- [ ] **Step 2: Test manually**

Run: `./scripts/shell-group.sh` (no args) — should show usage and group list.
Run: `./scripts/shell-group.sh main --shell` — should drop into bash.
Run: `./scripts/shell-group.sh main` — should launch claude.

- [ ] **Step 3: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "feat: default shell-group to launching claude instead of bash"
```

---

### Task 2: Add credential proxy and timezone env vars

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Read TZ and CREDENTIAL_PROXY_PORT from .env**

Add after the `BASE_DIR` line:

```bash
# Read additional config from .env
if [ -f "$PROJECT_ROOT/.env" ]; then
  eval "$(grep '^TZ=' "$PROJECT_ROOT/.env" 2>/dev/null)" || true
  eval "$(grep '^CREDENTIAL_PROXY_PORT=' "$PROJECT_ROOT/.env" 2>/dev/null)" || true
fi
TZ="${TZ:-UTC}"
CREDENTIAL_PROXY_PORT="${CREDENTIAL_PROXY_PORT:-3001}"
```

- [ ] **Step 2: Detect bridge IP for Apple Container**

Add a function to detect the bridge IP (same logic as `container-runtime.ts`):

```bash
detect_bridge_ip() {
  # Apple Container uses a vmnet bridge (bridge100+) with 192.168.64.x subnet
  ifconfig 2>/dev/null | awk '
    /^bridge[0-9]+:/ { iface=1; next }
    /^[^ \t]/ { iface=0 }
    iface && /inet 192\.168\.64\./ { print $2; exit }
  '
}
```

- [ ] **Step 3: Build ENV_ARGS array**

Add before the `container run` command:

```bash
ENV_ARGS=()
ENV_ARGS+=(-e "TZ=$TZ")

# Credential proxy: containers route API calls through the host proxy
BRIDGE_IP=$(detect_bridge_ip)
HOST_GW="${BRIDGE_IP:-host.docker.internal}"
ENV_ARGS+=(-e "ANTHROPIC_BASE_URL=http://${HOST_GW}:${CREDENTIAL_PROXY_PORT}")

# Detect auth mode from .env (same logic as credential-proxy.ts)
if grep -q '^ANTHROPIC_API_KEY=' "$PROJECT_ROOT/.env" 2>/dev/null; then
  ENV_ARGS+=(-e "ANTHROPIC_API_KEY=placeholder")
else
  ENV_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=placeholder")
fi
```

- [ ] **Step 4: Test manually**

Run: `./scripts/shell-group.sh main --shell`
Inside container: `echo $TZ` — should match host TZ.
Inside container: `echo $ANTHROPIC_BASE_URL` — should be `http://<bridge-ip>:3001`.

- [ ] **Step 5: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "feat: add credential proxy and timezone env vars to shell-group"
```

---

### Task 3: Read `is_main` from DB instead of hardcoding

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Update DB query to include is_main**

Change the SQL query from:

```bash
ROW=$(sqlite3 "$DB" "SELECT name, folder, container_config FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
```

To:

```bash
ROW=$(sqlite3 "$DB" "SELECT name, folder, container_config, COALESCE(is_main, 0) FROM registered_groups WHERE folder = '$FOLDER' LIMIT 1;")
```

Update parsing:

```bash
NAME=$(echo "$ROW" | cut -d'|' -f1)
CONTAINER_CONFIG=$(echo "$ROW" | cut -d'|' -f3)
IS_MAIN=$(echo "$ROW" | cut -d'|' -f4)
```

- [ ] **Step 2: Replace hardcoded main check**

Change:

```bash
if [ "$FOLDER" = "main" ]; then
```

To:

```bash
if [ "$IS_MAIN" = "1" ]; then
```

- [ ] **Step 3: Test manually**

Run: `./scripts/shell-group.sh main --shell` — should still mount `/workspace/project`.
Run: `./scripts/shell-group.sh weather --shell` — should NOT mount `/workspace/project`.

- [ ] **Step 4: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "fix: read is_main from DB instead of hardcoding folder name"
```

---

### Task 4: Parse and apply additional mounts from container_config

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Parse additionalMounts JSON and build mount args**

Add after the main-group mount block:

```bash
# Additional mounts from container_config.additionalMounts
if [ -n "$CONTAINER_CONFIG" ]; then
  # Extract additionalMounts array using python3 (available in container, also on macOS)
  ADDITIONAL_MOUNTS=$(python3 -c "
import json, sys
try:
    cfg = json.loads(sys.argv[1])
    for m in cfg.get('additionalMounts', []):
        hp = m['hostPath'].replace('~', '$HOME')
        cp = m.get('containerPath', hp.split('/')[-1])
        ro = 'true' if m.get('readonly', True) else 'false'
        print(f'{hp}|{cp}|{ro}')
except Exception:
    pass
" "$CONTAINER_CONFIG" 2>/dev/null || true)

  while IFS='|' read -r HOST_PATH CONTAINER_PATH READONLY; do
    [ -z "$HOST_PATH" ] && continue
    # Expand ~ in host path
    HOST_PATH="${HOST_PATH/#\~/$HOME}"
    # Mount at /workspace/extra/<containerPath>
    MOUNT_TARGET="/workspace/extra/$CONTAINER_PATH"
    if [ "$READONLY" = "true" ]; then
      MOUNT_ARGS+=(--mount "type=bind,source=$HOST_PATH,target=$MOUNT_TARGET,readonly")
    else
      MOUNT_ARGS+=(-v "$HOST_PATH:$MOUNT_TARGET")
    fi
    echo "  extra: $HOST_PATH -> $MOUNT_TARGET $([ "$READONLY" = "true" ] && echo "(ro)" || echo "(rw)")"
  done <<< "$ADDITIONAL_MOUNTS"
fi
```

- [ ] **Step 2: Test manually**

Run: `./scripts/shell-group.sh main --shell`
Inside container: `ls /workspace/extra/` — should show additional mount dirs from main's config.

Run with a group that has additional mounts (check DB for which groups have them).

- [ ] **Step 3: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "feat: apply additional mounts from container_config"
```

---

### Task 5: Sync skills before launch

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Add skills sync logic**

Add before the mount display block:

```bash
# Sync global skills into group's .claude/skills/ (same as container-runner.ts)
SKILLS_SRC="$PROJECT_ROOT/container/skills"
SKILLS_DST="$SESSIONS_DIR/skills"
if [ -d "$SKILLS_SRC" ]; then
  for skill_dir in "$SKILLS_SRC"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name=$(basename "$skill_dir")
    mkdir -p "$SKILLS_DST/$skill_name"
    cp -r "$skill_dir"* "$SKILLS_DST/$skill_name/" 2>/dev/null || true
  done
  echo "Synced skills: $(ls "$SKILLS_SRC" 2>/dev/null | tr '\n' ' ')"
fi
```

- [ ] **Step 2: Test manually**

Run: `./scripts/shell-group.sh main --shell`
Inside container: `ls /home/node/.claude/skills/` — should show synced skills.

- [ ] **Step 3: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "feat: sync global skills before container launch"
```

---

### Task 6: Store mount for main group

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Add store rw mount for main**

Inside the `if [ "$IS_MAIN" = "1" ]` block, add:

```bash
  # Main agent gets read-write access to the store (for direct DB queries)
  MOUNT_ARGS+=(-v "$BASE_DIR/store:/workspace/project/store")
```

This shadows the read-only store from the `/workspace/project` mount with a writable one.

- [ ] **Step 2: Test manually**

Run: `./scripts/shell-group.sh main --shell`
Inside container: `touch /workspace/project/store/test && rm /workspace/project/store/test` — should succeed.

- [ ] **Step 3: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "feat: mount store rw for main group in shell-group"
```

---

### Task 7: Final cleanup and usage polish

**Files:**
- Modify: `scripts/shell-group.sh`

- [ ] **Step 1: Update usage message**

```bash
if [ -z "${1:-}" ]; then
  echo "Usage: $0 [--shell] <group-folder>"
  echo ""
  echo "  Launches Claude Code inside a group's agent container."
  echo "  --shell    Drop to bash instead of launching Claude Code"
  echo ""
  echo "Available groups:"
  sqlite3 "$DB" "SELECT '  ' || folder || ' (' || name || CASE WHEN is_main = 1 THEN ', main' ELSE '' END || ')' FROM registered_groups ORDER BY folder;"
  exit 1
fi
```

- [ ] **Step 2: Update info display to show env vars**

Update the info block to also show key env vars:

```bash
echo ""
echo "Environment:"
echo "  TZ=$TZ"
echo "  ANTHROPIC_BASE_URL=http://${HOST_GW}:${CREDENTIAL_PROXY_PORT}"
echo ""
```

- [ ] **Step 3: End-to-end test**

Run: `./scripts/shell-group.sh` — shows usage with `--shell` flag documented.
Run: `./scripts/shell-group.sh main` — launches claude with full context.
Run: `./scripts/shell-group.sh pa --shell` — drops to bash with pa's additional mounts.

- [ ] **Step 4: Commit**

```bash
git add scripts/shell-group.sh
git commit -m "chore: polish shell-group usage and info display"
```
