# Intent: src/channels/index.ts modifications

## What changed
Added `import './whatsapp.js';` after the `// whatsapp` comment placeholder.

## Why
Upstream ships this barrel file with all channel imports commented out. Each
installation enables only the channels it uses. This installation uses WhatsApp
as its primary channel, so the import must be present for the service to start.

## Key sections

### WhatsApp import
- The line `import './whatsapp.js';` must appear immediately after the `// whatsapp` comment
- This triggers whatsapp.ts to call registerChannel(), which registers the WhatsApp adapter

## Invariants
- Other channel comment placeholders (discord, gmail, slack, telegram) remain as-is
- The file header comment is unchanged
- If upstream adds new channel placeholders, they should be preserved as comments

## Must-keep
- The `import './whatsapp.js';` line — without it, the service fatals with "No channels connected"
