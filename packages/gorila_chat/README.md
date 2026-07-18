# gorila_chat

Shared chat core used by **Family Chat** (reference) and **TeamCoach**.

## Layout

```text
familychat_app/packages/gorila_chat/   ← this package
teamcoach_app  → path: ../familychat_app/packages/gorila_chat
```

After changing the package, rebuild consumers (`flutter pub get` + run).

## What lives here

- `GorilaChatRealtime` — WS with reconnect / backoff / `chat_refresh` (Family Chat behaviour)
- Message utils — normalize, upsert, merge, thread_id-safe compare
- `ChatConversationSession` — apply WS events to an open thread
- Contracts — `ChatCapabilities`, `ChatHost`, `ChatRepository`
- Feature matrix — see `lib/src/util/feature_matrix.dart`

## What stays in apps

- HTTP API adapters (`familychat/*` vs `teamcoach/*`)
- Brand UI / navigation shell
- Domain renderers (albums, workout system cards)
- Capability-gated features the backend does not support

## Wire-up

```dart
final realtime = GorilaChatRealtime(
  debugName: 'teamcoach',
  uriForToken: (token) => Env.teamcoachWsUri(token),
);
await realtime.connect(accessToken);

// On AppLifecycleState.resumed:
await realtime.reconnectAndRefresh();
```

Open conversation should listen for `chat_message` and `chat_refresh` (reload via HTTP).

## Capabilities

Use `ChatCapabilities.familyChat` or `ChatCapabilities.teamCoach` (see `feature_matrix.dart`). Host apps implement `ChatRepository` / `ChatHost`; the package does not call Family Chat or TeamCoach HTTP directly.

## iPhone / Android verification (TeamCoach open chat)

1. Clone `familychat_app` next to `teamcoach_app` (path dependency).
2. `flutter pub get` in TeamCoach, run on device.
3. Open a chat thread and leave it open.
4. From another device/account, send a message into that thread.
5. **Pass:** the bubble appears within ~1–6s without leaving the screen
   (WS event, FCM soft-refresh, or soft-sync poll).
6. Background the app ~30s, resume — WS reconnects and open chat resyncs.
7. DM AppBar / info sheet show peer avatar when `avatar_url` exists.
8. Attach (+) opens gallery grid sheet (not a plain list of 3 rows).
