import 'dart:developer' as developer;

/// Diagnostics for chat media flicker (photo/video remount / URL churn).
///
/// Filter in logcat / Console: `ChatMediaFlicker`.
abstract final class ChatMediaFlickerTrace {
  static const logName = 'ChatMediaFlicker';

  /// Skip identical lines within this window (list rebuild spam).
  static final Map<String, DateTime> _lastAt = {};
  static const _dedupeWindow = Duration(milliseconds: 800);

  static void log(
    String phase, {
    int? threadId,
    int? attachmentId,
    String? detail,
    Map<String, Object?> extra = const {},
  }) {
    final parts = <String>['[$logName]', 'phase=$phase'];
    if (threadId != null) parts.add('thread=$threadId');
    if (attachmentId != null) parts.add('att=$attachmentId');
    if (detail != null && detail.isNotEmpty) parts.add(detail);
    for (final entry in extra.entries) {
      parts.add('${entry.key}=${entry.value}');
    }
    final line = parts.join(' ');
    final key = '$phase|${threadId ?? 0}|${attachmentId ?? 0}|$detail';
    final now = DateTime.now();
    final prev = _lastAt[key];
    if (prev != null && now.difference(prev) < _dedupeWindow) return;
    _lastAt[key] = now;
    if (_lastAt.length > 200) {
      _lastAt.remove(_lastAt.keys.first);
    }
    developer.log(line, name: logName);
    // ignore: avoid_print — intentional diagnostics (single sink; avoid print+debugPrint dupes)
    print(line);
  }
}

/// Host+path without query (presign signatures change; object identity does not).
String chatMediaUrlIdentity(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) return raw;
  final host = uri.host;
  final path = uri.path;
  if (host.isEmpty && path.isEmpty) return raw;
  return '${uri.scheme}://$host$path';
}

/// Stable disk/memory cache key for an attachment (survives URL re-sign).
String? chatAttachmentStableCacheKey({
  required int threadId,
  required int? attachmentId,
}) {
  if (attachmentId == null || attachmentId <= 0) return null;
  return 'fc_att_${threadId}_$attachmentId';
}
