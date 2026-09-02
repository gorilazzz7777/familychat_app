import 'package:flutter/foundation.dart';

/// Debug trace for inline reply from notification shade.
abstract final class PushReplyTrace {
  static void log(
    String phase, {
    int? threadId,
    int? messageId,
    String? source,
    String? detail,
    Map<String, Object?> extra = const {},
  }) {
    if (!kDebugMode) return;
    final parts = <String>['[PushReplyTrace]', 'phase=$phase'];
    if (threadId != null) parts.add('thread=$threadId');
    if (messageId != null) parts.add('message_id=$messageId');
    if (source != null && source.isNotEmpty) parts.add('src=$source');
    if (detail != null && detail.isNotEmpty) parts.add(detail);
    for (final entry in extra.entries) {
      parts.add('${entry.key}=${entry.value}');
    }
    debugPrint(parts.join(' '));
  }
}
