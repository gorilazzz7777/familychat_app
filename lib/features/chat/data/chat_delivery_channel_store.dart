import 'dart:convert';

import 'package:gorila_chat/gorila_chat.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sticky delivery channel preference per FC thread.
abstract final class ChatDeliveryChannelStore {
  static const _key = 'familychat_delivery_channel_by_thread_v1';

  static Future<ChatDeliveryChannel?> load(int threadId) async {
    if (threadId <= 0) return null;
    final prefs = await SharedPreferences.getInstance();
    final map = _decode(prefs.getString(_key));
    final raw = map['$threadId'];
    return _fromApi(raw);
  }

  static Future<void> save(int threadId, ChatDeliveryChannel channel) async {
    if (threadId <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final map = _decode(prefs.getString(_key));
    final api = _toApi(channel);
    if (api == null) {
      map.remove('$threadId');
    } else {
      map['$threadId'] = api;
    }
    await prefs.setString(_key, jsonEncode(map));
  }

  static String? _toApi(ChatDeliveryChannel channel) {
    return switch (channel) {
      ChatDeliveryChannel.auto => null,
      ChatDeliveryChannel.notifyFamilychat => 'notify_familychat',
      ChatDeliveryChannel.telegram => 'telegram',
      ChatDeliveryChannel.familychatOnly => 'familychat',
    };
  }

  static ChatDeliveryChannel? _fromApi(Object? raw) {
    final s = raw?.toString().trim().toLowerCase() ?? '';
    return switch (s) {
      'notify_familychat' || 'familychat_notify' =>
        ChatDeliveryChannel.notifyFamilychat,
      'telegram' || 'tg' => ChatDeliveryChannel.telegram,
      'familychat' || 'fc' || 'familychat_only' || 'fc_only' =>
        ChatDeliveryChannel.familychatOnly,
      'auto' || '' => null,
      _ => null,
    };
  }

  static Map<String, String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key != null && e.value != null)
            e.key.toString(): e.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }
}
