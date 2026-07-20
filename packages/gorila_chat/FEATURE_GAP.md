# Feature gap: Family Chat vs `gorila_chat`

Shared package now includes:
- message actions sheet (Select / Pin / Delete / Delete-for-me)
- pinned bar + cycle scroll
- multi-select with row highlight
- AI assist: long-press send → inline compose (draft from input → API → replace input; no intermediate screen)
- repository hooks: `pin` / `unpin` / `hideMessagesForMe` / `deleteMessages` / `aiComposeMessage`
- capability flags: `supportsPin`, `supportsSelect`, `supportsDeleteForMe`, `supportsAiAssist`

Optional: `ChatAiComposeScreen` still exported for hosts that want a custom task UI.

## Still only in Family Chat app (not fully in shared UI)

1. **Rich message bubble** — swipe-to-reply, quotes, reactions chips, voice player, location preview, mentions rendering, read receipts icon, image album
2. **Reply / edit / forward flows** — menu emits actions; Family still owns compose/edit/forward screens
3. **Reactions apply** — menu can pick emoji; toggle API not wired in `GorilaConversationScreen`
4. **Voice messages** — record, send, transcription (Vosk / premium)
5. **Location attach** + map compose
6. **Family gallery / albums attach** + face tagging
7. **Mentions** compose autocomplete
8. **Offline outbox / prefetch / local cache**
9. **Silent / scheduled send** — sheet exists in package; Family owns full schedule outbox; shared screen only uses AI from the menu
10. **In-thread message search**
11. **Birthday celebration** banners + scheduled congratulations
12. **Call history banners** in thread (Family has app-local call stack duplicate)
13. **Typing + presence** subtitles
14. **Pagination** load-older (shared screen loads one page)
15. **Chat hub** — filters, friends tab + Individual Premium gate, create group/friend invite
16. **Share-into-chat** target screen
17. **Leave / rejoin / rename / hide friend** in info sheet (Family-specific)

TeamCoach keeps using `GorilaConversationScreen` with `ChatCapabilities.teamCoach` (AI/pin/select off until backend exists).
