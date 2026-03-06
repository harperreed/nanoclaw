# Intent: src/types.ts modifications

## What changed
Added `reactToMessage` optional method to the `Channel` interface and
`syncGroups` optional method.

## Key sections

### Channel interface — reactToMessage
- Added optional method: `reactToMessage?(jid, messageId, emoji, fromMe): Promise<void>`
- Allows channels to support emoji reactions on messages
- Optional because not all channel backends support reactions

### Channel interface — syncGroups
- Added optional method: `syncGroups?(force: boolean): Promise<void>`
- Replaces the WhatsApp-specific `syncGroupMetadata` with a generic name

### RegisteredGroup — isMain
- Added: `isMain?: boolean` to RegisteredGroup interface
- Replaces the old `MAIN_GROUP_FOLDER` string comparison

## Invariants
- `reactToMessage` must remain optional (not all channels implement it)
- `syncGroups` must remain optional
- All other Channel interface members are unchanged

## Must-keep
- The `reactToMessage` method signature on Channel
- The `syncGroups` method signature on Channel
- The `isMain` field on RegisteredGroup
