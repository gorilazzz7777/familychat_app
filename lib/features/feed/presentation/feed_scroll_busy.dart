import 'package:flutter/foundation.dart';

/// Feed list fling/drag gate — defer network, media sync, and list setState.
class FeedScrollBusy {
  FeedScrollBusy._();

  static bool _busy = false;
  static bool _flinging = false;
  static final List<VoidCallback> _idleWaiters = [];

  static bool get isBusy => _busy;

  /// True only during ballistic inertia — slow drag must still show photos.
  static bool get isFlinging => _flinging;

  static void setBusy({bool flinging = false}) {
    _busy = true;
    _flinging = flinging;
  }

  static void clear() {
    if (!_busy && _idleWaiters.isEmpty) {
      _flinging = false;
      return;
    }
    _busy = false;
    _flinging = false;
    final waiters = List<VoidCallback>.from(_idleWaiters);
    _idleWaiters.clear();
    for (final cb in waiters) {
      try {
        cb();
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('[feed-scroll-busy] idle waiter failed: $e\n$st');
        }
      }
    }
  }

  /// Runs [cb] immediately if idle; otherwise once when scroll settles.
  static void onIdle(VoidCallback cb) {
    if (!_busy) {
      cb();
      return;
    }
    _idleWaiters.add(cb);
  }
}
