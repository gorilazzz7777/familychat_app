import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Temporary feed scroll jank probe. Filter logcat by `[feed-jank]`.
class FeedJankLog {
  FeedJankLog._();

  static bool enabled = kDebugMode;
  static bool focused = false;

  static DateTime? _lastScrollLogAt;
  static DateTime? _lastBuildLogAt;
  static int _itemBuilderTicks = 0;
  static int _buildCount = 0;
  static int _aspectResizeCount = 0;
  static int _slowFrameCount = 0;

  static void reset() {
    focused = true;
    _itemBuilderTicks = 0;
    _buildCount = 0;
    _aspectResizeCount = 0;
    _slowFrameCount = 0;
    log('focus feed');
  }

  static void clearFocus() {
    if (!focused) return;
    log(
      'unfocus builds=$_buildCount items=$_itemBuilderTicks '
      'aspectResize=$_aspectResizeCount slowFrames=$_slowFrameCount',
    );
    focused = false;
  }

  static void log(String msg) {
    if (!enabled || !focused) return;
    debugPrint('[feed-jank] $msg');
  }

  static void frame(FrameTiming t) {
    if (!enabled || !focused) return;
    final buildMs = t.buildDuration.inMilliseconds;
    final rasterMs = t.rasterDuration.inMilliseconds;
    final totalMs = t.totalSpan.inMilliseconds;
    if (buildMs < 18 && rasterMs < 18 && totalMs < 22) return;
    _slowFrameCount++;
    log(
      'FRAME build=${buildMs}ms raster=${rasterMs}ms '
      'total=${totalMs}ms vsync=${t.vsyncOverhead.inMilliseconds}ms',
    );
  }

  static void scroll({
    required double pixels,
    required double max,
    required String activity,
    required double velocity,
  }) {
    if (!enabled || !focused) return;
    final now = DateTime.now();
    final last = _lastScrollLogAt;
    if (last != null && now.difference(last).inMilliseconds < 80) return;
    _lastScrollLogAt = now;
    log(
      'SCROLL px=${pixels.toStringAsFixed(0)}/${max.toStringAsFixed(0)} '
      'act=$activity vel=${velocity.toStringAsFixed(0)}',
    );
  }

  static void build({required int ms, required int events, required int rows}) {
    if (!enabled || !focused) return;
    _buildCount++;
    final now = DateTime.now();
    final last = _lastBuildLogAt;
    _lastBuildLogAt = now;
    final gap = last == null ? -1 : now.difference(last).inMilliseconds;
    if (ms < 8 && gap >= 0 && gap < 200 && _buildCount % 5 != 0) return;
    log(
      'BUILD #$_buildCount ${ms}ms events=$events rows=$rows gap=${gap}ms',
    );
  }

  static void itemBuilderTick() {
    if (!enabled || !focused) return;
    _itemBuilderTicks++;
  }

  static void flushItemBuilderWindow() {
    if (!enabled || !focused) return;
    if (_itemBuilderTicks <= 0) return;
    log('ITEM_BUILDER ticks=$_itemBuilderTicks (since last flush)');
    _itemBuilderTicks = 0;
  }

  static void aspectResize({
    required String key,
    required double from,
    required double to,
    required bool locked,
    required bool deferred,
  }) {
    if (!enabled || !focused) return;
    _aspectResizeCount++;
    log(
      'ASPECT #$_aspectResizeCount key=$key '
      'from=${from.toStringAsFixed(2)}→${to.toStringAsFixed(2)} '
      'lock=$locked deferred=$deferred',
    );
  }

  static void mediaSync(String phase, {int? count}) {
    if (!enabled || !focused) return;
    log('MEDIA_SYNC phase=$phase${count == null ? '' : ' count=$count'}');
  }

  static void loadMore({required bool started, int? added}) {
    if (!enabled || !focused) return;
    log(
      started
          ? 'LOAD_MORE start'
          : 'LOAD_MORE done added=${added ?? 0}',
    );
  }
}
