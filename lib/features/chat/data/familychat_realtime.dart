import 'package:gorila_chat/gorila_chat.dart';

import '../../../core/config/env.dart';
import '../../../core/network/auth_token_refresher.dart';

/// Family Chat realtime facade — delegates to shared [GorilaChatRealtime].
class FamilyChatRealtime {
  FamilyChatRealtime._();

  static final GorilaChatRealtime instance = GorilaChatRealtime(
    debugName: 'familychat',
    uriForToken: Env.familychatWsUri,
  );

  static bool _resolverBound = false;

  /// Wire JWT proactive refresh into WS connect/reconnect (once per process).
  static void bindAuthRefresher(AuthTokenRefresher refresher) {
    instance.setAccessTokenResolver(() => refresher.ensureAccess());
    _resolverBound = true;
  }

  static bool get isAuthResolverBound => _resolverBound;
}
