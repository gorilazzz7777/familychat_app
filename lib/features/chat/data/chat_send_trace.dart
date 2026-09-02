import 'package:flutter/foundation.dart';

import 'chat_realtime_utils.dart';

/// Debug trace for chat send races (optimistic UI ↔ SQLite ↔ WS ↔ outbox).
abstract final class ChatSendTrace {
  static void log(
    String phase, {
    int? threadId,
    int? tempId,
    int? serverId,
    String? source,
    String? detail,
    Map<String, Object?> extra = const {},
  }) {
    if (!kDebugMode) return;
    final parts = <String>['[ChatSendTrace]', 'phase=$phase'];
    if (threadId != null) parts.add('thread=$threadId');
    if (tempId != null) parts.add('temp=$tempId');
    if (serverId != null) parts.add('server=$serverId');
    if (source != null && source.isNotEmpty) parts.add('src=$source');
    if (detail != null && detail.isNotEmpty) parts.add(detail);
    for (final entry in extra.entries) {
      parts.add('${entry.key}=${entry.value}');
    }
    debugPrint(parts.join(' '));
  }

  static String idsSummary(
    List<Map<String, dynamic>> messages, {
    int max = 10,
  }) {
    if (messages.isEmpty) return '[]';
    final ids = <String>[];
    for (final m in messages) {
      final id = chatAsInt(m['id']);
      if (id == null) continue;
      final pending = m['_pending'] == true ? 'p' : '';
      final status = m['read_status']?.toString() ?? '';
      final tag = status.isNotEmpty ? '$id$pending($status)' : '$id$pending';
      ids.add(tag);
    }
    if (ids.length <= max) return '[${ids.join(', ')}]';
    final head = ids.take(max ~/ 2).join(', ');
    final tail = ids.skip(ids.length - max ~/ 2).join(', ');
    return '[$head … ${ids.length} total … $tail]';
  }

  static String idDiff(
    List<Map<String, dynamic>> before,
    List<Map<String, dynamic>> after,
  ) {
    final beforeIds = <int>{
      for (final m in before)
        if (chatAsInt(m['id']) != null) chatAsInt(m['id'])!,
    };
    final afterIds = <int>{
      for (final m in after)
        if (chatAsInt(m['id']) != null) chatAsInt(m['id'])!,
    };
    final removed = beforeIds.difference(afterIds).toList()..sort();
    final added = afterIds.difference(beforeIds).toList()..sort();
    if (removed.isEmpty && added.isEmpty) return 'ids=unchanged';
    return 'removed=$removed added=$added';
  }
}
