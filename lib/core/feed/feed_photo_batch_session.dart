import 'dart:math';

import '../../features/familychat/data/familychat_repository.dart';

String createFeedPhotoBatchId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int value) => value.toRadixString(16).padLeft(2, '0');
  final raw = bytes.map(hex).join();
  return '${raw.substring(0, 8)}-${raw.substring(8, 12)}-'
      '${raw.substring(12, 16)}-${raw.substring(16, 20)}-${raw.substring(20)}';
}

/// Одна пользовательская сессия загрузки фото → одно событие ленты.
class FeedPhotoBatchSession {
  FeedPhotoBatchSession({int totalTasks = 0})
      : batchId = createFeedPhotoBatchId(),
        _remaining = totalTasks;

  final String batchId;
  int _remaining;

  void addTasks(int count) {
    if (count > 0) _remaining += count;
  }

  Future<void> markAttemptFinished(FamilyChatRepository repo) async {
    if (_remaining > 0) _remaining--;
    if (_remaining <= 0) {
      await repo.completeFeedPhotoBatch(batchId);
    }
  }
}
