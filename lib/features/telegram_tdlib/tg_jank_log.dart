import 'package:flutter/foundation.dart';

/// Temporary jank probe for TG conversation (НСИС…). Filter logcat by `[tg-jank]`.
class TgJankLog {
  TgJankLog._();

  static bool enabled = kDebugMode;
  static int? focusChatId;

  static DateTime? _lastScrollLogAt;
  static DateTime? _lastNotifyLogAt;
  static DateTime? _lastBuildLogAt;
  static int _itemBuilderTicks = 0;
  static int _buildCount = 0;
  static int _notifyCount = 0;

  static void resetForChat(int chatId) {
    focusChatId = chatId;
    _itemBuilderTicks = 0;
    _buildCount = 0;
    _notifyCount = 0;
    log('focus chat=$chatId');
  }

  static void clearFocus() {
    log(
      'unfocus chat=$focusChatId builds=$_buildCount notifies=$_notifyCount '
      'itemBuilder=$_itemBuilderTicks',
    );
    focusChatId = null;
  }

  static void log(String msg) {
    if (!enabled) return;
    debugPrint('[tg-jank] $msg');
  }

  static void build({
    required int chatId,
    required int ms,
    required int msgs,
    required int rows,
    required bool contentReady,
    required bool linkPreviews,
  }) {
    if (!enabled || focusChatId != chatId) return;
    _buildCount++;
    final now = DateTime.now();
    final last = _lastBuildLogAt;
    _lastBuildLogAt = now;
    final gap = last == null ? -1 : now.difference(last).inMilliseconds;
    // Always log slow builds; throttle fast ones.
    if (ms < 8 && gap >= 0 && gap < 200 && _buildCount % 5 != 0) return;
    log(
      'BUILD #$_buildCount ${ms}ms msgs=$msgs rows=$rows '
      'ready=$contentReady links=$linkPreviews gap=${gap}ms',
    );
  }

  static void scroll({
    required int chatId,
    required double pixels,
    required double max,
    required String activity,
    required bool busy,
  }) {
    if (!enabled || focusChatId != chatId) return;
    final now = DateTime.now();
    final last = _lastScrollLogAt;
    if (last != null && now.difference(last).inMilliseconds < 80) return;
    _lastScrollLogAt = now;
    log(
      'SCROLL px=${pixels.toStringAsFixed(0)}/${max.toStringAsFixed(0)} '
      'act=$activity busy=$busy',
    );
  }

  static void notify({
    required String reason,
    bool deferred = false,
    bool immediate = false,
  }) {
    if (!enabled || focusChatId == null) return;
    _notifyCount++;
    final now = DateTime.now();
    final last = _lastNotifyLogAt;
    if (!immediate &&
        last != null &&
        now.difference(last).inMilliseconds < 40 &&
        _notifyCount % 8 != 0) {
      return;
    }
    _lastNotifyLogAt = now;
    log(
      'NOTIFY #$_notifyCount reason=$reason '
      'deferred=$deferred immediate=$immediate',
    );
  }

  static void itemBuilderTick() {
    if (!enabled || focusChatId == null) return;
    _itemBuilderTicks++;
  }

  static void flushItemBuilderWindow() {
    if (!enabled || focusChatId == null) return;
    if (_itemBuilderTicks <= 0) return;
    log('ITEM_BUILDER ticks=$_itemBuilderTicks (since last flush)');
    _itemBuilderTicks = 0;
  }

  static void linkPreview(String url, {required String phase}) {
    if (!enabled) return;
    log('LINK_PREVIEW phase=$phase url=$url');
  }
}
