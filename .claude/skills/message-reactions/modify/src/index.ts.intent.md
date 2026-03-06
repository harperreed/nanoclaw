# Intent: src/index.ts modifications

## What changed
Wired `reactToMessage` into the IPC deps object so container agents
can send reactions via the react_to_message IPC type.

## Key sections

### IPC deps — reactToMessage
- Added `reactToMessage` function to the deps object passed to `startIpcWatcher`
- Looks up the channel for the target JID
- Calls `channel.reactToMessage()` if supported, warns if not
- Pattern: `(jid, messageId, emoji, fromMe) => { findChannel... }`

## Invariants
- Uses `findChannel(channels, jid)` to resolve the correct channel (multi-channel aware)
- Gracefully handles channels that don't support reactions (logs warning, resolves)
- Must appear in the same deps object as sendMessage, syncGroups, etc.

## Must-keep
- The reactToMessage wiring in IPC deps
- The channel lookup + fallback pattern
