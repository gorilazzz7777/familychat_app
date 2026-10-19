import 'dart:async';

import 'package:flutter/widgets.dart';

/// Exactly one muted looping inline video in a chat list.
///
/// - Candidates report visibility + distance to viewport center.
/// - Scroll does **not** unload the active player — keep playing while the
///   video stays in the active band ([minVisibleFraction]).
/// - After [settleDelay] without scroll, nearest visible candidate may win
///   (switch). Current winner keeps playing until it leaves the band or
///   another candidate wins after settle.
/// - Hysteresis keeps the current winner so tiny layout jitter does not flip.
class ChatInlineVideoAutoplayController extends ChangeNotifier {
  ChatInlineVideoAutoplayController({
    this.settleDelay = const Duration(milliseconds: 480),
    this.minVisibleFraction = 0.42,
  });

  /// Delay after last scroll / visibility change before starting / switching.
  final Duration settleDelay;
  final double minVisibleFraction;

  String? _activeKey;
  bool _scrolling = false;
  final Map<String, _InlineVideoCandidate> _candidates = {};
  Timer? _settleTimer;

  String? get activeKey => _activeKey;
  bool get isScrolling => _scrolling;

  void noteScroll() {
    if (_scrolling) return;
    _scrolling = true;
    _settleTimer?.cancel();
    // Keep [_activeKey] — unload only when off the active band or another wins.
  }

  void noteScrollEnd() {
    if (!_scrolling) {
      _armSettle();
      return;
    }
    _scrolling = false;
    _armSettle();
  }

  /// [distanceToCenter] — absolute px from video center to viewport focus line.
  void report(
    String key, {
    required double visibleFraction,
    required double distanceToCenter,
  }) {
    if (key.isEmpty) return;
    if (visibleFraction < minVisibleFraction ||
        !distanceToCenter.isFinite) {
      final removed = _candidates.remove(key);
      if (removed == null) return;
      final wasActive = _activeKey == key;
      if (wasActive) {
        _activeKey = null;
        notifyListeners();
      }
      // Pick a still-visible replacement after settle (even mid-scroll once
      // the active left the band — otherwise nothing plays until scroll-end).
      _armSettle(allowDuringScroll: wasActive);
      return;
    }
    _candidates[key] = _InlineVideoCandidate(
      visibleFraction: visibleFraction,
      distanceToCenter: distanceToCenter,
    );
    if (!_scrolling) _armSettle();
  }

  void unregister(String key) {
    if (key.isEmpty) return;
    _candidates.remove(key);
    if (_activeKey == key) {
      _activeKey = null;
      notifyListeners();
      _armSettle(allowDuringScroll: true);
    }
  }

  void _armSettle({bool allowDuringScroll = false}) {
    _settleTimer?.cancel();
    if (_scrolling && !allowDuringScroll) return;
    _settleTimer = Timer(settleDelay, _pickWinner);
  }

  void _pickWinner() {
    // While scrolling, only fill an empty slot — never steal from a still-
    // visible active player (avoids thrash during fast fling).
    if (_scrolling && _activeKey != null) return;
    if (_candidates.isEmpty) {
      if (_activeKey != null) {
        _activeKey = null;
        notifyListeners();
      }
      return;
    }

    String? bestKey;
    var bestDist = double.infinity;
    for (final e in _candidates.entries) {
      if (e.value.distanceToCenter < bestDist) {
        bestDist = e.value.distanceToCenter;
        bestKey = e.key;
      }
    }
    if (bestKey == null) return;

    // Keep current if still visible and not much farther than the new best.
    final curKey = _activeKey;
    if (curKey != null) {
      final cur = _candidates[curKey];
      if (cur != null && cur.distanceToCenter <= bestDist * 1.4) {
        return;
      }
    }

    if (bestKey != _activeKey) {
      _activeKey = bestKey;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _candidates.clear();
    super.dispose();
  }
}

class _InlineVideoCandidate {
  const _InlineVideoCandidate({
    required this.visibleFraction,
    required this.distanceToCenter,
  });

  final double visibleFraction;
  final double distanceToCenter;
}

class ChatInlineVideoAutoplayScope
    extends InheritedNotifier<ChatInlineVideoAutoplayController> {
  const ChatInlineVideoAutoplayScope({
    super.key,
    required ChatInlineVideoAutoplayController controller,
    required super.child,
  }) : super(notifier: controller);

  static ChatInlineVideoAutoplayController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ChatInlineVideoAutoplayScope>()
        ?.notifier;
  }
}
