import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:share_handler/share_handler.dart';

/// Входящие данные из системного меню «Поделиться».
class IncomingShareBus {
  IncomingShareBus._();

  static final IncomingShareBus instance = IncomingShareBus._();

  SharedMedia? _pending;
  StreamSubscription<SharedMedia>? _subscription;
  final List<VoidCallback> _listeners = [];

  SharedMedia? get pending => _pending;

  bool get hasPending => _pending != null;

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  Future<void> init() async {
    if (kIsWeb) return;

    final handler = ShareHandlerPlatform.instance;
    final initial = await handler.getInitialSharedMedia();
    if (initial != null) {
      _pending = initial;
      _notify();
    }

    await _subscription?.cancel();
    _subscription = handler.sharedMediaStream.listen((media) {
      _pending = media;
      _notify();
    });
  }

  SharedMedia? takePending() {
    final media = _pending;
    _pending = null;
    return media;
  }

  void _notify() {
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }
}
