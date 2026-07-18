# gorila_chat

Self-contained chat module (UI + realtime + contracts). Apps differ only by API adapters.

## Layout

```text
familychat_app/packages/gorila_chat/
teamcoach_app  → path: ../familychat_app/packages/gorila_chat
```

## Public API

- `GorilaConversationScreen` — conversation UI (bubbles, compose, attach, info, calls)
- `ChatAttachSheet` — Family Chat–style gallery/file sheet
- `ChatCallScreen` / `IncomingCallScreen` / `IncomingCallCoordinator`
- `GorilaChatRealtime` — WS reconnect + `chat_refresh`
- `ChatRepository` / `ChatCallRepository` / `ChatHost` / `ChatCapabilities`

## TeamCoach wire-up

```dart
final adapter = TeamCoachChatAdapter(repo, mode: TeamCoachChatMode.dm)
  ..peerUserId = peerId;

GorilaConversationScreen(
  threadId: threadId,
  title: title,
  repository: adapter,
  callRepository: adapter,
  realtime: TeamCoachRealtime.instance,
  capabilities: ChatCapabilities.teamCoach,
  systemMessageBuilder: (ctx, msg) => /* workout cards */,
);

IncomingCallCoordinator.instance.configure(
  navigatorKey: teamCoachNavigatorKey,
  callRepository: adapter,
  realtime: TeamCoachRealtime.instance,
  pushType: 'teamcoach_call',
);
```

## Verification

1. Open chat → incoming message appears without leaving.
2. Attach (+) → gallery grid (not a plain list).
3. DM AppBar / info show avatar when `avatar_url` exists.
4. Call: callee gets fullscreen incoming via WS **and** FCM `teamcoach_call`; after accept, two-way audio.
