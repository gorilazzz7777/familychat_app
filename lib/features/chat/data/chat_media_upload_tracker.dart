import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class ChatMediaUploadState {
  const ChatMediaUploadState({
    this.progress = 0,
    this.active = false,
  });

  final double progress;
  final bool active;
}

/// Прогресс и отмена исходящих загрузок вложений (по temp message id).
class ChatMediaUploadTracker extends ChangeNotifier {
  ChatMediaUploadTracker();

  static ChatMediaUploadTracker? shared;
  final Map<int, ChatMediaUploadState> _states = {};
  final Map<int, CancelToken> _tokens = {};
  final Set<int> _cancelled = {};

  ChatMediaUploadState stateFor(int tempMessageId) {
    return _states[tempMessageId] ?? const ChatMediaUploadState();
  }

  bool isCancelled(int tempMessageId) => _cancelled.contains(tempMessageId);

  CancelToken begin(int tempMessageId) {
    if (_cancelled.contains(tempMessageId)) {
      throw StateError('upload_cancelled');
    }
    final token = CancelToken();
    _tokens[tempMessageId] = token;
    _states[tempMessageId] = const ChatMediaUploadState(active: true, progress: 0);
    notifyListeners();
    return token;
  }

  void update(int tempMessageId, double progress) {
    if (_cancelled.contains(tempMessageId)) return;
    final clamped = progress.clamp(0.0, 1.0);
    _states[tempMessageId] = ChatMediaUploadState(
      active: true,
      progress: clamped,
    );
    notifyListeners();
  }

  void cancel(int tempMessageId) {
    _cancelled.add(tempMessageId);
    _tokens[tempMessageId]?.cancel('user_cancelled');
    _tokens.remove(tempMessageId);
    _states.remove(tempMessageId);
    notifyListeners();
  }

  void complete(int tempMessageId) {
    _tokens.remove(tempMessageId);
    _states.remove(tempMessageId);
    _cancelled.remove(tempMessageId);
    notifyListeners();
  }

  void resetCancellation(int tempMessageId) {
    _cancelled.remove(tempMessageId);
  }
}
