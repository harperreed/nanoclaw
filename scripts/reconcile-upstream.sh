#!/usr/bin/env bash
# ABOUTME: Reconcile fork with upstream NanoClaw changes.
# ABOUTME: Auto-applies safe upstream-only changes, protects customizations and secrets.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel)"
TODAY="$(date +%Y-%m-%d)"
BRANCH_NAME="reconcile-${TODAY}"
REPORT_FILE="${REPO_ROOT}/reconcile-report.md"

# Secrets blocklist — files matching these patterns are NEVER modified
SECRETS_PATTERNS=(
  ".env"
  ".env.*"
  "*.pem"
  "*.key"
  "*.p12"
  "*secret*"
  "*credential*"
  "*token*"
  "mount-allowlist.json"
  "sender-allowlist.json"
)

# ── Helpers ──────────────────────────────────────────────────────────────────

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "→ $*"
}

warn() {
  echo "⚠ $*" >&2
}

# Check if a file path matches any secrets pattern.
# Uses bash-native pattern matching (fnmatch-style via case).
is_sensitive() {
  local file="$1"
  local basename
  basename="$(basename "$file")"

  for pattern in "${SECRETS_PATTERNS[@]}"; do
    # shellcheck disable=SC2254
    case "$basename" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

usage() {
  cat <<'USAGE'
Usage: reconcile-upstream.sh [OPTIONS]

Reconcile this NanoClaw fork with upstream changes.

Options:
  --dry-run       Classify and report only, don't apply changes
  --show <file>   Show what upstream changed in a specific file
  -h, --help      Show this help message

The script:
  1. Fetches upstream/main
  2. Classifies every changed file into 4 buckets
  3. Creates a reconcile-YYYY-MM-DD branch from main
  4. Auto-applies upstream-only changes (safe)
  5. Skips secrets and sensitive files (always)
  6. Reports conflicts for manual review
  7. Commits auto-applied changes
USAGE
}

# ── Argument Parsing ─────────────────────────────────────────────────────────

DRY_RUN=false
SHOW_FILE=""
AUTO_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --yes|-y)
      AUTO_YES=true
      shift
      ;;
    --show)
      [ $# -lt 2 ] && die "--show requires a file argument"
      SHOW_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# ── Preconditions ────────────────────────────────────────────────────────────

# Must be in a git repo
git rev-parse --git-dir > /dev/null 2>&1 || die "Not in a git repository"

# Upstream remote must exist
if ! git remote get-url upstream > /dev/null 2>&1; then
  cat >&2 <<'MSG'
ERROR: No 'upstream' remote found.

Set it up with:
  git remote add upstream https://github.com/qwibitai/nanoclaw.git
  git fetch upstream
MSG
  exit 1
fi

# Working tree must be clean
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Working tree is dirty. Commit or stash changes first."
fi

# Check for untracked files that would interfere
if [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  warn "Untracked files detected — they won't affect reconciliation but consider cleaning up."
fi

# ── Fetch Upstream ───────────────────────────────────────────────────────────

info "Fetching upstream..."
git fetch upstream

# ── Handle --show mode ───────────────────────────────────────────────────────

if [ -n "$SHOW_FILE" ]; then
  MERGE_BASE="$(git merge-base main upstream/main)"
  info "Upstream changes to ${SHOW_FILE} since merge-base (${MERGE_BASE:0:8}):"
  echo ""
  git diff "$MERGE_BASE" upstream/main -- "$SHOW_FILE"
  exit 0
fi

# ── Compute Merge Base ───────────────────────────────────────────────────────

MERGE_BASE="$(git merge-base main upstream/main)"
info "Merge base: ${MERGE_BASE:0:12}"

# ── Get All Changed Files ────────────────────────────────────────────────────

# Files that differ between main and upstream/main
CHANGED_FILES=()
while IFS= read -r file; do
  [ -n "$file" ] && CHANGED_FILES+=("$file")
done < <(git diff --name-only main upstream/main 2>/dev/null || true)

if [ "${#CHANGED_FILES[@]}" -eq 0 ]; then
  info "Already up to date — no differences between main and upstream/main."
  exit 0
fi

info "Found ${#CHANGED_FILES[@]} files with differences."

# ── Classify Files ───────────────────────────────────────────────────────────

UPSTREAM_ONLY=()
LOCAL_ONLY=()
BOTH_CHANGED=()
SENSITIVE=()

for file in "${CHANGED_FILES[@]}"; do
  # Check secrets blocklist first
  if is_sensitive "$file"; then
    SENSITIVE+=("$file")
    continue
  fi

  # Did upstream change this file since merge-base?
  upstream_changed=false
  if ! git diff --quiet "$MERGE_BASE" upstream/main -- "$file" 2>/dev/null; then
    upstream_changed=true
  fi

  # Did we change this file locally since merge-base?
  local_changed=false
  if ! git diff --quiet "$MERGE_BASE" main -- "$file" 2>/dev/null; then
    local_changed=true
  fi

  if [ "$upstream_changed" = true ] && [ "$local_changed" = false ]; then
    UPSTREAM_ONLY+=("$file")
  elif [ "$upstream_changed" = false ] && [ "$local_changed" = true ]; then
    LOCAL_ONLY+=("$file")
  elif [ "$upstream_changed" = true ] && [ "$local_changed" = true ]; then
    BOTH_CHANGED+=("$file")
  fi
  # If neither changed (shouldn't happen), skip silently
done

# ── Print Summary ────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   Upstream Reconciliation Summary    ║"
echo "╠══════════════════════════════════════╣"
printf "║  Auto-apply (upstream only): %-5d   ║\n" "${#UPSTREAM_ONLY[@]}"
printf "║  Keep (local only):         %-5d   ║\n" "${#LOCAL_ONLY[@]}"
printf "║  Needs review (both):       %-5d   ║\n" "${#BOTH_CHANGED[@]}"
printf "║  Sensitive (skipped):       %-5d   ║\n" "${#SENSITIVE[@]}"
echo "╚══════════════════════════════════════╝"
echo ""

# Print sensitive file warnings
if [ "${#SENSITIVE[@]}" -gt 0 ]; then
  warn "Sensitive files with upstream changes (review manually):"
  for file in "${SENSITIVE[@]}"; do
    echo "  - $file"
  done
  echo ""
fi

# ── Generate Report ──────────────────────────────────────────────────────────

generate_report() {
  local upstream_version local_version
  upstream_version="$(git show upstream/main:package.json 2>/dev/null | grep '"version"' | head -1 | sed 's/.*"\([0-9.]*\)".*/\1/' || echo "unknown")"
  local_version="$(git show main:package.json 2>/dev/null | grep '"version"' | head -1 | sed 's/.*"\([0-9.]*\)".*/\1/' || echo "unknown")"

  cat > "$REPORT_FILE" <<EOF
# Upstream Reconciliation Report — ${TODAY}

## Summary
- Upstream version: ${upstream_version}
- Local version: ${local_version}
- Merge base: ${MERGE_BASE:0:12}
- Files auto-applied: ${#UPSTREAM_ONLY[@]}
- Files kept (local only): ${#LOCAL_ONLY[@]}
- Files needing review: ${#BOTH_CHANGED[@]}
- Sensitive files skipped: ${#SENSITIVE[@]}

## Auto-Applied (upstream only)
EOF

  if [ "${#UPSTREAM_ONLY[@]}" -gt 0 ]; then
    for file in "${UPSTREAM_ONLY[@]}"; do
      local desc
      desc="$(git log --oneline "${MERGE_BASE}..upstream/main" -- "$file" | head -1 || echo "no commit info")"
      echo "- \`${file}\` — ${desc}" >> "$REPORT_FILE"
    done
  else
    echo "_None_" >> "$REPORT_FILE"
  fi

  cat >> "$REPORT_FILE" <<EOF

## Kept (local only)
EOF

  if [ "${#LOCAL_ONLY[@]}" -gt 0 ]; then
    for file in "${LOCAL_ONLY[@]}"; do
      echo "- \`${file}\`" >> "$REPORT_FILE"
    done
  else
    echo "_None_" >> "$REPORT_FILE"
  fi

  cat >> "$REPORT_FILE" <<EOF

## Needs Review (both changed)
EOF

  if [ "${#BOTH_CHANGED[@]}" -gt 0 ]; then
    for file in "${BOTH_CHANGED[@]}"; do
      echo "- \`${file}\`" >> "$REPORT_FILE"
      echo "  - Upstream commits:" >> "$REPORT_FILE"
      git log --oneline "${MERGE_BASE}..upstream/main" -- "$file" 2>/dev/null | while IFS= read -r line; do
        echo "    - ${line}" >> "$REPORT_FILE"
      done
      echo "  - Local commits:" >> "$REPORT_FILE"
      git log --oneline "${MERGE_BASE}..main" -- "$file" 2>/dev/null | while IFS= read -r line; do
        echo "    - ${line}" >> "$REPORT_FILE"
      done
    done
  else
    echo "_None_" >> "$REPORT_FILE"
  fi

  cat >> "$REPORT_FILE" <<EOF

## Sensitive (skipped)
EOF

  if [ "${#SENSITIVE[@]}" -gt 0 ]; then
    for file in "${SENSITIVE[@]}"; do
      echo "- \`${file}\` — upstream has changes, review manually" >> "$REPORT_FILE"
    done
  else
    echo "_None_" >> "$REPORT_FILE"
  fi
}

generate_report
info "Report written to ${REPORT_FILE}"

# ── Dry Run Exit ─────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = true ]; then
  info "Dry run complete. No changes applied."
  echo ""
  echo "Review the report: ${REPORT_FILE}"
  echo "Run without --dry-run to apply upstream-only changes."
  exit 0
fi

# ── Confirmation Gate ────────────────────────────────────────────────────────

if [ "${#UPSTREAM_ONLY[@]}" -eq 0 ]; then
  info "No upstream-only files to auto-apply."
  echo "Review the report for files needing manual attention: ${REPORT_FILE}"
  exit 0
fi

echo "This will:"
echo "  • Create branch '${BRANCH_NAME}' from main"
echo "  • Auto-apply ${#UPSTREAM_ONLY[@]} upstream-only file(s)"
echo "  • Commit the changes"
echo ""

if [ "$AUTO_YES" = false ]; then
  read -r -p "Proceed? [y/N] " confirm < /dev/tty
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    info "Aborted."
    exit 0
  fi
fi

# ── Create Branch ────────────────────────────────────────────────────────────

# Check if branch already exists
if git rev-parse --verify "$BRANCH_NAME" > /dev/null 2>&1; then
  die "Branch '${BRANCH_NAME}' already exists. Delete it first or run again tomorrow."
fi

info "Creating branch '${BRANCH_NAME}' from main..."
git checkout -b "$BRANCH_NAME" main

# ── Auto-Apply Upstream-Only Changes ─────────────────────────────────────────

info "Applying ${#UPSTREAM_ONLY[@]} upstream-only changes..."

for file in "${UPSTREAM_ONLY[@]}"; do
  # Create parent directory if needed (file may be new from upstream)
  mkdir -p "$(dirname "$file")"
  # Use git show to write the file (works for both new and existing files)
  git show "upstream/main:${file}" > "$file"
  git add "$file"
  echo "  ✓ ${file}"
done

# ── Commit ───────────────────────────────────────────────────────────────────

git commit -m "$(cat <<EOF
feat: reconcile upstream changes (${TODAY})

Auto-applied ${#UPSTREAM_ONLY[@]} upstream-only file(s).
Skipped ${#BOTH_CHANGED[@]} file(s) needing manual review.
Skipped ${#SENSITIVE[@]} sensitive file(s).

See reconcile-report.md for details.
EOF
)"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           Reconciliation Done        ║"
echo "╠══════════════════════════════════════╣"
echo "║  Branch: ${BRANCH_NAME}              "
echo "║  Auto-applied: ${#UPSTREAM_ONLY[@]} file(s)"
echo "╚══════════════════════════════════════╝"
echo ""

if [ "${#BOTH_CHANGED[@]}" -gt 0 ]; then
  echo "Next steps for conflicted files:"
  echo "  1. Review the report: ${REPORT_FILE}"
  echo "  2. For each conflicted file, compare:"
  echo "     ./scripts/reconcile-upstream.sh --show <file>"
  echo "  3. Manually resolve each file on this branch"
  echo "  4. When satisfied, merge into main:"
  echo "     git checkout main && git merge ${BRANCH_NAME}"
else
  echo "No conflicts! You can merge directly:"
  echo "  git checkout main && git merge ${BRANCH_NAME}"
fi
