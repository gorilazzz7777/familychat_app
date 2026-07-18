import 'package:gorila_chat/gorila_chat.dart';

import '../../../core/config/env.dart';

/// Family Chat realtime facade — delegates to shared [GorilaChatRealtime].
class FamilyChatRealtime {
  FamilyChatRealtime._();

  static final GorilaChatRealtime instance = GorilaChatRealtime(
    debugName: 'familychat',
    uriForToken: Env.familychatWsUri,
  );
}
