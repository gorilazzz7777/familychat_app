import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../profile/presentation/widgets/chat_avatar.dart';
import '../../data/chat_message_preview.dart';
import '../../data/chat_realtime_utils.dart';
import '../chat_thread_avatars.dart';
import 'chat_message_read_status_icon.dart';

/// Строка чата как в главном списке, с подсветкой выбранных (как в «Поделиться»).
class ChatThreadSelectTile extends StatelessWidget {
  const ChatThreadSelectTile({
    super.key,
    required this.thread,
    required this.selected,
    required this.onTap,
    this.memberByUserId = const {},
  });

  final Map<String, dynamic> thread;
  final bool selected;
  final VoidCallback onTap;
  final Map<int, Map<String, dynamic>> memberByUserId;

  static int? dmPeerUserId(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    if (kind != 'dm' && kind != 'friend_dm') return null;
    return chatAsInt(thread['peer_user_id']);
  }

  static String? dmAvatarUrl(
    Map<String, dynamic> thread,
    Map<int, Map<String, dynamic>> memberByUserId,
  ) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return fromThread;
    final peerId = dmPeerUserId(thread);
    if (peerId == null) return null;
    final url = memberByUserId[peerId]?['avatar_url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  static String titleOf(
    Map<String, dynamic> thread,
    Map<int, Map<String, dynamic>> memberByUserId,
  ) {
    final peerId = dmPeerUserId(thread);
    if (peerId != null) {
      final display =
          memberByUserId[peerId]?['display_name']?.toString().trim();
      if (display != null && display.isNotEmpty) return display;
    }
    return thread['title']?.toString() ?? 'Чат';
  }

  static String previewOf(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    return chatMessagePreviewText(last);
  }

  static String? lastMessageReadStatus(Map<String, dynamic>? last) {
    if (last == null || last['is_system'] == true) return null;
    final status = last['read_status']?.toString().trim();
    if (status == null || status.isEmpty) return null;
    return status;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = titleOf(thread, memberByUserId);
    final last = thread['last_message'] as Map<String, dynamic>?;
    final lastStatus = lastMessageReadStatus(last);
    final created = last != null
        ? DateTime.tryParse(last['created_at']?.toString() ?? '')
        : null;
    final isBirthday = thread['is_birthday_celebration'] == true;
    final avatarAsset = chatThreadAvatarAsset(
      kind: thread['kind']?.toString() ?? '',
      isBirthdayCelebration: isBirthday,
    );
    final bg = selected ? scheme.primaryContainer : Colors.transparent;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    final subFg = selected
        ? scheme.onPrimaryContainer.withValues(alpha: 0.8)
        : scheme.onSurfaceVariant;
    final previewStyle = theme.textTheme.bodyMedium?.copyWith(color: subFg);
    final timeStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 11,
      color: subFg.withValues(alpha: 0.8),
    );

    return Material(
      color: bg,
      child: ListTile(
        onTap: onTap,
        leading: ChatAvatar(
          name: title,
          avatarUrl: avatarAsset != null
              ? null
              : dmAvatarUrl(thread, memberByUserId),
          userId: avatarAsset != null ? null : dmPeerUserId(thread),
          assetPath: avatarAsset,
          radius: 24,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (lastStatus != null) ...[
                      ChatMessageReadStatusIcon(
                        status: lastStatus,
                        color: subFg,
                        size: 15,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        previewOf(thread),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: previewStyle,
                      ),
                    ),
                  ],
                ),
              ),
              if (created != null) ...[
                const SizedBox(width: 8),
                Text(
                  DateFormat('HH:mm').format(created.toLocal()),
                  style: timeStyle,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
