import 'dart:async';

import '../../familychat/data/familychat_repository.dart';

/// Deduplicates concurrent hub bootstrap (threads + members).
class ChatBootstrapCoordinator {
  ChatBootstrapCoordinator._();

  static final ChatBootstrapCoordinator instance = ChatBootstrapCoordinator._();

  Future<void>? _hubInFlight;
  DateTime? _lastHubFinishedAt;
  static const _minHubGap = Duration(seconds: 8);

  bool get hubRecentlySynced {
    final at = _lastHubFinishedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < _minHubGap;
  }

  Future<void> syncHubOnce(
    FamilyChatRepository repo, {
    required Future<void> Function() body,
  }) async {
    if (_hubInFlight != null) {
      return _hubInFlight!;
    }
    final future = body().whenComplete(() {
      _lastHubFinishedAt = DateTime.now();
      _hubInFlight = null;
    });
    _hubInFlight = future;
    return future;
  }
}
