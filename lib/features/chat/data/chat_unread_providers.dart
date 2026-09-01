import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/local_db/chat_local_store.dart';
import '../../../core/providers/app_providers.dart';

int chatNotifiedUnreadFromThreads(Iterable<Map<String, dynamic>> threads) {
  var total = 0;
  for (final thread in threads) {
    if (thread['notifications_enabled'] as bool? ?? true) {
      final unread = thread['unread_count'];
      if (unread is int) {
        total += unread;
      } else {
        total += int.tryParse('$unread') ?? 0;
      }
    }
  }
  return total;
}

/// Сумма непрочитанных в чатах с включёнными уведомлениями.
///
/// Native: следит SQLite ([watchThreads]) — без гонки invalidate → 0 на FutureProvider.
/// Web: одноразовый HTTP; обновление через [invalidateChatUnreadTotal].
final chatUnreadTotalProvider = StreamProvider<int>((ref) async* {
  if (ChatLocalStore.isSupported) {
    await for (final threads in ChatLocalStore.instance.watchThreads()) {
      yield chatNotifiedUnreadFromThreads(threads);
    }
    return;
  }
  try {
    final threads = await ref.read(familychatRepositoryProvider).chatThreads();
    yield chatNotifiedUnreadFromThreads(threads);
  } catch (_) {
    yield 0;
  }
});

class ChatUnreadRefresh {
  ChatUnreadRefresh._();

  /// Wired by shell to invalidate [chatUnreadTotalProvider] after SQLite writes.
  static void Function()? onInvalidate;
}

void invalidateChatUnreadTotal(WidgetRef ref) {
  ref.invalidate(chatUnreadTotalProvider);
}
