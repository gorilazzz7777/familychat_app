import 'package:flutter/widgets.dart';

/// When to show a light stub in the bubble instead of decoding full media.
abstract final class ChatMediaDisplayPolicy {
  static const deferredFullMediaAge = Duration(days: 5);

  /// Session expansions: tap «Загрузить» keeps full bubble decode until app restart.
  static final Set<String> _expanded = <String>{};

  static String attachmentKey(int threadId, int attachmentId) =>
      '$threadId:$attachmentId';

  static bool isExpanded(int threadId, int attachmentId) =>
      _expanded.contains(attachmentKey(threadId, attachmentId));

  static void markExpanded(int threadId, int attachmentId) {
    if (attachmentId <= 0) return;
    _expanded.add(attachmentKey(threadId, attachmentId));
  }

  static bool isOlderThanDeferredAge(DateTime? createdAt, {DateTime? now}) {
    if (createdAt == null) return false;
    final clock = now ?? DateTime.now();
    return clock.difference(createdAt) >= deferredFullMediaAge;
  }

  /// Defer full decode in the bubble until the user taps Load.
  static bool shouldDeferFullDecode({
    required int threadId,
    required int? attachmentId,
    required DateTime? messageCreatedAt,
    DateTime? now,
  }) {
    if (attachmentId == null || attachmentId <= 0) return false;
    if (!isOlderThanDeferredAge(messageCreatedAt, now: now)) return false;
    if (isExpanded(threadId, attachmentId)) return false;
    return true;
  }

  /// Pixel width for Flutter / CachedNetworkImage decode (bubble logical size × DPR).
  static int? memCacheWidthPx(BuildContext context, double? logicalWidth) {
    if (logicalWidth == null ||
        logicalWidth <= 0 ||
        !logicalWidth.isFinite) {
      return null;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (logicalWidth * dpr).round().clamp(32, 1600);
  }

  static int? memCacheHeightPx(BuildContext context, double? logicalHeight) {
    if (logicalHeight == null ||
        logicalHeight <= 0 ||
        !logicalHeight.isFinite) {
      return null;
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (logicalHeight * dpr).round().clamp(32, 1600);
  }

  /// Tiny decode for deferred / stub previews (~text-level RAM).
  static int lightMemCacheWidthPx(BuildContext context, double? logicalWidth) {
    final full = memCacheWidthPx(context, logicalWidth);
    if (full == null) return 64;
    return (full * 0.18).round().clamp(32, 96);
  }
}
