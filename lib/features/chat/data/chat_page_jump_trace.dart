import 'package:flutter/foundation.dart';

import 'chat_realtime_utils.dart';

/// Temporary diagnostics for history scroll jumps. Filter logs by `[ChatPageJump]`.
abstract final class ChatPageJumpTrace {
  static int _seq = 0;

  static void log(
    String phase, {
    int? threadId,
    String? detail,
    Map<String, Object?> extra = const {},
  }) {
    if (!kDebugMode) return;
    _seq += 1;
    final parts = <String>[
      '[ChatPageJump]',
      '#$_seq',
      phase,
      if (threadId != null) 'thread=$threadId',
      if (detail != null && detail.isNotEmpty) detail,
    ];
    for (final entry in extra.entries) {
      parts.add('${entry.key}=${entry.value}');
    }
    debugPrint(parts.join(' '));
  }

  static String shortDate(Map<String, dynamic>? message) {
    if (message == null) return '-';
    final raw = message['created_at']?.toString() ?? '';
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw.isEmpty ? '-' : raw;
    final mm = dt.month.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$min';
  }

  static String windowSummary(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return 'empty';
    final first = messages.first;
    final last = messages.last;
    final firstId = chatAsInt(first['id']);
    final lastId = chatAsInt(last['id']);
    return 'n=${messages.length} '
        'oldest=$firstId@${shortDate(first)} '
        'newest=$lastId@${shortDate(last)}';
  }

  static String? dateGapHint(
    List<Map<String, dynamic>> before,
    List<Map<String, dynamic>> after,
  ) {
    if (before.isEmpty || after.isEmpty) return null;
    final beforeFirst = DateTime.tryParse(
      before.first['created_at']?.toString() ?? '',
    );
    final afterFirst = DateTime.tryParse(
      after.first['created_at']?.toString() ?? '',
    );
    if (beforeFirst == null || afterFirst == null) return null;
    final deltaDays =
        afterFirst.toUtc().difference(beforeFirst.toUtc()).inDays;
    if (deltaDays.abs() < 2) return null;
    return 'OLDEST_DATE_JUMP_DAYS=$deltaDays '
        'before=${shortDate(before.first)} after=${shortDate(after.first)}';
  }
}
