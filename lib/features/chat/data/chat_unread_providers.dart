import 'package:flutter_riverpod/flutter_riverpod.dart';

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
final chatUnreadTotalProvider = FutureProvider<int>((ref) async {
  try {
    final threads = await ref.read(familychatRepositoryProvider).chatThreads();
    return chatNotifiedUnreadFromThreads(threads);
  } catch (_) {
    return 0;
  }
});

class ChatUnreadRefresh {
  ChatUnreadRefresh._();

  static void Function()? onInvalidate;
}

void invalidateChatUnreadTotal(WidgetRef ref) {
  ref.invalidate(chatUnreadTotalProvider);
  ChatUnreadRefresh.onInvalidate?.call();
}
