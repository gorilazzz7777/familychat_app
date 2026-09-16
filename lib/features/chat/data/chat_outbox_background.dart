import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../familychat/data/familychat_repository.dart';
import 'chat_offline_outbox.dart';
import 'chat_offline_sync.dart';
import 'chat_send_trace.dart';

/// iOS background outbox flush: beginBackgroundTask + BGAppRefresh wakeups.
abstract final class ChatOutboxBackground {
  static const _channelName = 'com.familychat/outbox_background';
  static const MethodChannel _channel = MethodChannel(_channelName);

  static bool _handlerInstalled = false;
  static bool _flushInFlight = false;
  static FamilyChatRepository? _repo;

  /// Call once after login / shell start so native BGAppRefresh can invoke Dart.
  static void install(FamilyChatRepository repo) {
    _repo = repo;
    if (kIsWeb || !Platform.isIOS) return;
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'flushOutbox') {
        await _runFlush(reason: 'bg_refresh');
        return true;
      }
      return null;
    });
    unawaited(_channel.invokeMethod<void>('register'));
  }

  /// Extend process lifetime briefly and push pending outbox items.
  static Future<void> flushWhileBackgrounded(FamilyChatRepository repo) async {
    _repo = repo;
    if (kIsWeb) return;
    final pending = await ChatOfflineOutbox.pendingCount();
    if (pending <= 0) return;

    ChatSendTrace.log(
      'outbox_bg_flush_start',
      source: 'bg',
      extra: {'pending': pending},
    );

    if (Platform.isIOS) {
      try {
        await _channel.invokeMethod<void>('begin', {'reason': 'outbox'});
      } catch (e) {
        debugPrint('[ChatOutboxBackground] begin failed: $e');
      }
      try {
        await _channel.invokeMethod<void>('scheduleRefresh');
      } catch (_) {}
    }

    try {
      await _runFlush(reason: 'lifecycle_paused');
    } finally {
      if (Platform.isIOS) {
        try {
          await _channel.invokeMethod<void>('end');
        } catch (_) {}
      }
    }
  }

  static Future<void> _runFlush({required String reason}) async {
    if (_flushInFlight) return;
    final repo = _repo;
    if (repo == null) return;
    _flushInFlight = true;
    try {
      await ChatOfflineOutbox.resumePausedForNetworkRecovery();
      await ChatOfflineSync.instance.run(repo);
      ChatSendTrace.log(
        'outbox_bg_flush_done',
        source: 'bg',
        detail: reason,
      );
    } catch (e, st) {
      debugPrint('[ChatOutboxBackground] flush failed: $e\n$st');
    } finally {
      _flushInFlight = false;
    }
  }
}
