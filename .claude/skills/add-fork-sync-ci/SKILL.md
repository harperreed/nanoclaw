---
name: add-fork-sync-ci
description: Use when setting up automated upstream sync for a NanoClaw fork. Triggers on "fork sync", "upstream sync", "sync workflow", "github actions sync", "skill branch sync".
---

# Add Fork Sync CI

Adds a GitHub Actions workflow that automatically syncs your fork's `main` with upstream NanoClaw, then propagates changes into all `skill/*` branches. Failures open GitHub issues with remediation steps.

## When to Use

- Maintaining a NanoClaw fork with custom skill branches
- Want automated upstream sync on a schedule
- Need CI to validate builds after merges

## Step 1: Create Workflow

Create `.github/workflows/fork-sync-skills.yml`:

```yaml
name: Fork Sync + Skill Maintenance

on:
  repository_dispatch:
    types: [upstream-main-updated]
  schedule:
    - cron: '0 */6 * * *'  # every 6 hours
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write
  issues: write

concurrency:
  group: fork-sync
  cancel-in-progress: true

jobs:
  sync-and-maintain:
    if: github.repository != 'qwibitai/nanoclaw'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Sync with upstream main
        id: sync
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

          git remote add upstream https://github.com/qwibitai/nanoclaw.git || true
          git fetch upstream main

          if git merge-base --is-ancestor upstream/main HEAD; then
            echo "Already up to date with upstream"
            echo "synced=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi

          git merge upstream/main --no-edit || {
            echo "sync_failed=true" >> "$GITHUB_OUTPUT"
            git merge --abort
            git reset --hard origin/main
            exit 0
          }

          npm ci && npm run build && npm test || {
            echo "sync_failed=true" >> "$GITHUB_OUTPUT"
            git reset --hard origin/main
            exit 0
          }

          git push origin main
          echo "synced=true" >> "$GITHUB_OUTPUT"

      - name: Merge main into skill branches
        if: steps.sync.outputs.sync_failed != 'true'
        id: skills
        run: |
          FAILED=""
          SUCCEEDED=""

          for branch in $(git branch -r --list 'origin/skill/*' | sed 's|origin/||'); do
            echo "--- Merging main into $branch ---"
            git checkout -B "$branch" "origin/$branch"

            if git merge main --no-edit; then
              if npm ci && npm run build && npm test; then
                git push origin "$branch"
                SUCCEEDED="$SUCCEEDED $branch"
              else
                git reset --hard "origin/$branch"
                FAILED="$FAILED $branch(build-failed)"
              fi
            else
              git merge --abort
              git reset --hard "origin/$branch"
              FAILED="$FAILED $branch(merge-conflict)"
            fi
          done

          git checkout main

          if [ -n "$FAILED" ]; then
            echo "failed_branches=$FAILED" >> "$GITHUB_OUTPUT"
          fi
          if [ -n "$SUCCEEDED" ]; then
            echo "succeeded_branches=$SUCCEEDED" >> "$GITHUB_OUTPUT"
          fi

      - name: Open issue on sync failure
        if: steps.sync.outputs.sync_failed == 'true'
        uses: actions/github-script@v7
        with:
          script: |
            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '⚠️ Upstream sync failed',
              body: `Automatic merge of upstream/main failed.\n\nManual steps:\n\`\`\`bash\ngit fetch upstream main\ngit merge upstream/main\n# resolve conflicts\nnpm ci && npm run build && npm test\ngit push origin main\n\`\`\``,
              labels: ['upstream-sync']
            });

      - name: Open issue on skill branch failures
        if: steps.skills.outputs.failed_branches
        uses: actions/github-script@v7
        with:
          script: |
            const failed = '${{ steps.skills.outputs.failed_branches }}'.trim();
            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: '⚠️ Skill branch merge failed',
              body: `Failed branches: ${failed}\n\nFor each, manually:\n\`\`\`bash\ngit checkout <branch>\ngit merge main\n# resolve conflicts\nnpm ci && npm run build && npm test\ngit push origin <branch>\n\`\`\``,
              labels: ['skill-maintenance']
            });
```

## Step 2: Commit and Push

```bash
git add .github/workflows/fork-sync-skills.yml
git commit -m "ci: add fork sync + skill branch maintenance workflow"
git push
```

## Step 3: Verify

1. Go to the repo's Actions tab on GitHub
2. Trigger the workflow manually via "Run workflow"
3. Confirm it syncs with upstream and processes skill branches
4. Check that no spurious issues are opened

## Notes

- The `github.repository != 'qwibitai/nanoclaw'` guard prevents this from running on upstream if it gets pulled in
- Concurrency group `fork-sync` prevents parallel runs from racing
- On failure, the workflow resets to `origin/main` (or `origin/<branch>`) so no broken state is pushed
- Schedule runs every 6 hours; adjust the cron as needed
