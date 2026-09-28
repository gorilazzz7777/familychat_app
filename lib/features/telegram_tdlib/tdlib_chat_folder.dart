/// Manual (user-picked chats) Telegram folder for the chat hub.
class TdlibChatFolderInfo {
  const TdlibChatFolderInfo({
    required this.id,
    required this.title,
    required this.isManual,
  });

  final int id;
  final String title;

  /// True when the folder has no type filters (contacts/groups/channels/…).
  /// Only these are shown in the hub, per product rules.
  final bool isManual;
}

/// Helpers for TDLib chat-folder JSON payloads / parsing.
abstract final class TdlibChatFolderCodec {
  static const maxTitleLength = 12;

  static String truncateTitle(String name) {
    final t = name.trim().replaceAll('\n', ' ');
    if (t.length <= maxTitleLength) return t;
    return t.substring(0, maxTitleLength);
  }

  static String titleFromInfo(Map<String, dynamic> info) {
    final name = info['name'];
    if (name is Map) {
      final text = name['text'];
      if (text is Map) {
        final s = text['text']?.toString() ?? '';
        if (s.isNotEmpty) return s;
      } else if (text is String && text.isNotEmpty) {
        return text;
      }
    }
    final title = info['title'];
    if (title is String && title.isNotEmpty) return title;
    if (title is Map) {
      final text = title['text'];
      if (text is Map) return text['text']?.toString() ?? '';
      if (text is String) return text;
    }
    return '';
  }

  static bool isManualFolder(Map<String, dynamic> folder) {
    bool flag(String key) => folder[key] == true;
    // Type-filter / "smart" folders (Unread, Channels, …) — hide from hub.
    if (flag('include_contacts') ||
        flag('include_non_contacts') ||
        flag('include_bots') ||
        flag('include_groups') ||
        flag('include_channels') ||
        flag('exclude_read')) {
      return false;
    }
    return true;
  }

  static List<int> intIdList(dynamic raw) {
    if (raw is! List) return const [];
    final out = <int>[];
    for (final e in raw) {
      if (e is int) {
        out.add(e);
      } else if (e is num) {
        out.add(e.toInt());
      } else {
        final p = int.tryParse('$e');
        if (p != null) out.add(p);
      }
    }
    return out;
  }

  static Map<String, dynamic> namePayload(String title) {
    return {
      '@type': 'chatFolderName',
      'text': {
        '@type': 'formattedText',
        'text': truncateTitle(title),
        'entities': <Map<String, dynamic>>[],
      },
      'animate_custom_emoji': false,
    };
  }

  /// Build a [chatFolder] object for create/edit. Preserves fields from [base]
  /// when provided (icon, excludes, pinned, …).
  static Map<String, dynamic> folderPayload({
    required String title,
    required List<int> includedChatIds,
    Map<String, dynamic>? base,
    List<int>? pinnedChatIds,
    List<int>? excludedChatIds,
  }) {
    final pinned = pinnedChatIds ?? intIdList(base?['pinned_chat_ids']);
    final excluded = excludedChatIds ?? intIdList(base?['excluded_chat_ids']);
    return {
      '@type': 'chatFolder',
      'name': namePayload(title),
      if (base?['icon'] is Map) 'icon': base!['icon'],
      'color_id': (base?['color_id'] as num?)?.toInt() ?? -1,
      'is_shareable': base?['is_shareable'] == true,
      'pinned_chat_ids': pinned,
      'included_chat_ids': includedChatIds,
      'excluded_chat_ids': excluded,
      'exclude_muted': base?['exclude_muted'] == true,
      'exclude_read': false,
      'exclude_archived': base == null ? true : base['exclude_archived'] == true,
      'include_contacts': false,
      'include_non_contacts': false,
      'include_bots': false,
      'include_groups': false,
      'include_channels': false,
    };
  }

  static int? folderIdFromPositionList(dynamic list) {
    if (list is! Map) return null;
    if (list['@type']?.toString() != 'chatListFolder') return null;
    final id = list['chat_folder_id'];
    if (id is int) return id;
    if (id is num) return id.toInt();
    return int.tryParse('$id');
  }
}
