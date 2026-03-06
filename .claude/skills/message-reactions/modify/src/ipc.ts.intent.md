# Intent: src/ipc.ts modifications

## What changed
Added `react_to_message` IPC message type handling and `reactToMessage`
to the IPC dependencies interface.

## Key sections

### IpcDeps interface
- Added: `reactToMessage(jid, messageId, emoji, fromMe): Promise<void>`
- This is wired up in index.ts to call the channel's reactToMessage

### processMessageIpc — react_to_message case
- Added a new `else if` branch after the `send_message` branch
- Matches `data.type === 'react_to_message'` with `chatJid`, `messageId`, `emoji`
- Authorization: same rules as send_message (main can react anywhere, others only in own group)
- Calls `deps.reactToMessage(data.chatJid, data.messageId, data.emoji, false)`

## Invariants
- Authorization logic mirrors send_message exactly
- The react_to_message branch sits between send_message and the next IPC type
- IpcDeps must include reactToMessage (index.ts provides it)

## Must-keep
- The `reactToMessage` field in IpcDeps
- The `react_to_message` case with authorization checks
- Logging for both successful reactions and unauthorized attempts
