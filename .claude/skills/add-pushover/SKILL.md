---
name: add-pushover
description: Use when adding Pushover push notification support to NanoClaw containers. Triggers on "pushover", "push notifications", "push-cli", "push cli".
---

# Add Pushover Push Notifications

Installs [harperreed/push-cli](https://github.com/harperreed/push-cli) into the container so agents can send Pushover push notifications via the `push` binary.

## When to Use

- Agent needs to send push notifications to a phone/device
- Setting up alerting or notification capabilities

## Prerequisites

- Pushover account with API token and user key
- NanoClaw container builds working

## Step 1: Add to Dockerfile

In `container/Dockerfile`, find the `RUN set -ex; fetch ...` block that downloads GitHub release binaries (toki, gsuite-mcp, msgvault, pulse, etc.). Add a new line:

```dockerfile
fetch harperreed/push-cli    "Linux_arm64.tar.gz"  push
```

This follows the existing `fetch` pattern: `fetch <github-org/repo> <asset-glob> <target-binary-name>`.

## Step 2: Rebuild Container

```bash
./container/build.sh
```

## Step 3: Configure

Add Pushover credentials to `.env`:

```bash
PUSHOVER_TOKEN=your_app_token
PUSHOVER_USER=your_user_key
```

Ensure these env vars are forwarded to the container (add to the secrets list in `src/container-runner.ts` `readSecrets()` if not already present).

## Step 4: Verify

Send a test message to an agent asking it to send a push notification:

```
Send me a push notification saying "hello from nanoclaw"
```

The agent should run `push "hello from nanoclaw"` inside the container.

## Troubleshooting

- **"push: command not found"** — Container wasn't rebuilt after Dockerfile change
- **"unauthorized"** — Check `PUSHOVER_TOKEN` and `PUSHOVER_USER` in `.env`
- **Binary fetch fails** — Check that `harperreed/push-cli` has an `arm64` Linux release on GitHub
