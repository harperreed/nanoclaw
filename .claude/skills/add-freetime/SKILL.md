---
name: add-freetime
description: Use when adding autonomous research and blogging capability to NanoClaw agents. Triggers on "freetime", "agent hobbies", "autonomous research", "agent blog", "companion".
---

# Add Freetime — Autonomous Research & Blogging

Adds a container skill that gives agents autonomous "free time" for self-directed research, web exploration, and blogging. Each agent develops its own persona, interests, and persistent memory.

## When to Use

- User wants agents to have creative/research downtime
- Setting up the Cosmo companion persona
- Enabling agent blogging with approval workflow

## What It Does

- First invocation runs a **setup wizard** to configure persona (name, voice, interests, blog dir)
- Subsequent `/freetime [duration]` invocations start a research session
- Agent picks its own topics, browses the web, saves memories across sessions
- Blog posts require explicit user approval before writing to disk
- Synced to all groups via `container/skills/` global distribution

## Step 1: Create Container Skill

Read the companion file `freetime-skill-content.md` in this skill directory. Write its contents to `container/skills/freetime/SKILL.md`.

```bash
mkdir -p container/skills/freetime
```

Then use the Write tool to create `container/skills/freetime/SKILL.md` with the full content from `freetime-skill-content.md`.

## Step 2: Rebuild Container

```bash
./container/build.sh
```

The skill will be synced to all groups automatically (container skills in `container/skills/` are copied to each group's `.claude/skills/` before every run).

## Step 3: Verify

Send a message to any group: `/freetime 10m`

First run should trigger the setup wizard. After setup, subsequent invocations should start a research session.

## Notes

- Default persona is **Cosmo**: warm, curious, slightly formal
- Duration: `Nm`/`Nh` format, default 10m, clamped 5m–2h
- Memory stored at `~/.claude/freetime-memory/` (inside container)
- Blog posts written to user-configured directory with frontmatter (title, date, draft, tags, mood)
- No auto-commit, no auto-push — user manages publishing
- Topic choice is always the agent's — user cannot seed topics
