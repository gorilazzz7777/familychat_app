import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatRecentFileEntry {
  const ChatRecentFileEntry({
    required this.filename,
    required this.sizeBytes,
    this.path,
    this.contentType,
  });

  final String filename;
  final int sizeBytes;
  final String? path;
  final String? contentType;

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'sizeBytes': sizeBytes,
        if (path != null) 'path': path,
        if (contentType != null) 'contentType': contentType,
      };

  factory ChatRecentFileEntry.fromJson(Map<String, dynamic> json) {
    return ChatRecentFileEntry(
      filename: json['filename']?.toString() ?? 'file',
      sizeBytes: json['sizeBytes'] is int
          ? json['sizeBytes'] as int
          : int.tryParse('${json['sizeBytes']}') ?? 0,
      path: json['path']?.toString(),
      contentType: json['contentType']?.toString(),
    );
  }
}

class ChatRecentFilesStore {
  static const _key = 'familychat_chat_recent_files_v1';
  static const _max = 20;

  static Future<List<ChatRecentFileEntry>> load() async {
    if (kIsWeb) return const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((e) => ChatRecentFileEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> remember(ChatRecentFileEntry entry) async {
    if (kIsWeb) return;
    try {
      final current = await load();
      final next = <ChatRecentFileEntry>[
        entry,
        ...current.where((e) => e.filename != entry.filename || e.path != entry.path),
      ].take(_max).toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(next.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
