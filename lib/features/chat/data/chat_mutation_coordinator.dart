import 'dart:async';

import '../../familychat/data/familychat_repository.dart';
import '../../../core/local_db/chat_local_store.dart';
import 'chat_offline_sync.dart';

/// Native: all chat mutations go through outbox; network runs in background.
abstract final class ChatMutationCoordinator {
  static bool get useLocalFirst => ChatLocalStore.isSupported;

  static void scheduleSync(FamilyChatRepository repo) {
    if (!useLocalFirst) return;
    unawaited(ChatOfflineSync.instance.run(repo));
  }
}
