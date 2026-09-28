/// Hub chip: system filter (Все / Семья / Telegram), server custom folder,
/// or a manual Telegram folder from TDLib.
class HubChip {
  const HubChip.system(this.system)
      : folderId = null,
        folderName = null,
        tgFolderId = null;

  const HubChip.custom({
    required int id,
    required String name,
  })  : system = null,
        folderId = id,
        folderName = name,
        tgFolderId = null;

  const HubChip.telegram({
    required int id,
    required String name,
  })  : system = null,
        folderId = null,
        folderName = name,
        tgFolderId = id;

  final ChatHubSystemFilter? system;
  final int? folderId;
  final int? tgFolderId;
  final String? folderName;

  bool get isCustom => folderId != null;
  bool get isTelegramFolder => tgFolderId != null;

  String get key {
    if (isTelegramFolder) return 'tg:$tgFolderId';
    if (isCustom) return 'custom:$folderId';
    return system?.name ?? 'all';
  }

  String get label {
    if (isCustom || isTelegramFolder) return folderName ?? 'Папка';
    return switch (system!) {
      ChatHubSystemFilter.all => 'Все',
      ChatHubSystemFilter.family => 'Семья',
      ChatHubSystemFilter.telegram => 'Telegram',
    };
  }

  @override
  bool operator ==(Object other) => other is HubChip && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

enum ChatHubSystemFilter { all, family, telegram }

/// Membership key for folder membership matching against hub rows.
abstract final class ChatFolderMemberKey {
  static String forThread(int threadId) => 't:$threadId';
  static String forTg(int tgChatId) => 'tg:$tgChatId';

  /// Key for a hub list row (FC thread or TDLib synthetic).
  static String? forHubRow(Map<String, dynamic> row) {
    final kind = row['kind']?.toString() ?? '';
    if (kind == 'tdlib_dm' || kind == 'tdlib_chat') {
      final tg = (row['tdlib_chat_id'] as num?)?.toInt();
      if (tg != null) return forTg(tg);
      return null;
    }
    final id = row['id'];
    final threadId = id is int ? id : int.tryParse('$id');
    if (threadId != null && threadId > 0) return forThread(threadId);
    // Negative synthetic id without kind — fall back to tdlib_chat_id.
    final tg = (row['tdlib_chat_id'] as num?)?.toInt();
    if (tg != null) return forTg(tg);
    return null;
  }

  /// Payload for add/remove API from a hub row.
  static ({int? threadId, int? tgChatId})? apiIds(Map<String, dynamic> row) {
    final kind = row['kind']?.toString() ?? '';
    if (kind == 'tdlib_dm' || kind == 'tdlib_chat') {
      final tg = (row['tdlib_chat_id'] as num?)?.toInt();
      if (tg == null) return null;
      return (threadId: null, tgChatId: tg);
    }
    final id = row['id'];
    final threadId = id is int ? id : int.tryParse('$id');
    if (threadId != null && threadId > 0) {
      return (threadId: threadId, tgChatId: null);
    }
    final tg = (row['tdlib_chat_id'] as num?)?.toInt();
    if (tg != null) return (threadId: null, tgChatId: tg);
    return null;
  }
}

class ChatFolderData {
  ChatFolderData({
    required this.id,
    required this.name,
    required this.position,
    required this.memberKeys,
  });

  final int id;
  final String name;
  final int position;
  final Set<String> memberKeys;

  factory ChatFolderData.fromJson(Map<String, dynamic> json) {
    final members = <String>{};
    final raw = json['members'];
    if (raw is List) {
      for (final m in raw) {
        if (m is! Map) continue;
        final map = Map<String, dynamic>.from(m);
        final threadId = (map['thread_id'] as num?)?.toInt();
        final tgChatId = (map['tg_chat_id'] as num?)?.toInt();
        if (threadId != null) {
          members.add(ChatFolderMemberKey.forThread(threadId));
        } else if (tgChatId != null) {
          members.add(ChatFolderMemberKey.forTg(tgChatId));
        }
      }
    }
    return ChatFolderData(
      id: (json['id'] as num).toInt(),
      name: json['name']?.toString() ?? '',
      position: (json['position'] as num?)?.toInt() ?? 0,
      memberKeys: members,
    );
  }

  bool containsHubRow(Map<String, dynamic> thread) {
    final key = ChatFolderMemberKey.forHubRow(thread);
    return key != null && memberKeys.contains(key);
  }

  /// True if [memberKeys] contains a Telegram chat not matched to an FC contact.
  bool hasUnmatchedTgMember(Set<int> matchedTgChatIds) {
    for (final key in memberKeys) {
      if (!key.startsWith('tg:')) continue;
      final id = int.tryParse(key.substring(3));
      if (id == null || id == 0) continue;
      if (!matchedTgChatIds.contains(id)) return true;
    }
    return false;
  }

  List<int> tgChatIds() {
    final out = <int>[];
    for (final key in memberKeys) {
      if (!key.startsWith('tg:')) continue;
      final id = int.tryParse(key.substring(3));
      if (id != null && id != 0) out.add(id);
    }
    return out;
  }
}
