import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/family_app_bar.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../../telegram_tdlib/presentation/telegram_conversation_screen.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
import '../data/chat_hub_last_message_time.dart';
import '../data/chat_realtime_utils.dart';
import '../data/hub_first_paint_snapshot.dart';
import 'widgets/chat_message_read_status_icon.dart';

/// Telegram Archive list — same role as official TG «Архив чатов».
///
/// Cold start paints from [snapshotRows] / hub SQLite; live TDLib replaces
/// once `hubArchiveChats` lands (same flow as Main hub rows).
class TelegramArchiveScreen extends ConsumerStatefulWidget {
  const TelegramArchiveScreen({
    super.key,
    this.snapshotRows = const [],
  });

  /// Last-session archive synthetics from [HubFirstPaintSnapshot].
  final List<Map<String, dynamic>> snapshotRows;

  @override
  ConsumerState<TelegramArchiveScreen> createState() =>
      _TelegramArchiveScreenState();
}

class _TelegramArchiveScreenState extends ConsumerState<TelegramArchiveScreen> {
  final Set<int> _selected = {};
  bool _selectionMode = false;
  List<Map<String, dynamic>> _snapshotRows = const [];

  @override
  void initState() {
    super.initState();
    _snapshotRows = [
      for (final r in widget.snapshotRows) Map<String, dynamic>.from(r),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureSnapshot());
      unawaited(
        ref.read(telegramTdlibServiceProvider).refreshArchiveChatList(),
      );
    });
  }

  Future<void> _ensureSnapshot() async {
    if (_snapshotRows.isNotEmpty) return;
    final data =
        HubFirstPaintSnapshot.warmed ?? await HubFirstPaintSnapshot.read();
    if (!mounted || data == null) return;
    final archive = HubFirstPaintSnapshot.splitTgRows(data.rows).archive;
    if (archive.isEmpty) return;
    setState(() => _snapshotRows = archive);
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggle(int chatId) {
    setState(() {
      if (_selected.contains(chatId)) {
        _selected.remove(chatId);
        if (_selected.isEmpty) _selectionMode = false;
      } else {
        _selectionMode = true;
        _selected.add(chatId);
      }
    });
  }

  Future<void> _unarchiveSelected() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    await ref.read(telegramTdlibServiceProvider).unarchiveChats(ids);
    if (!mounted) return;
    final drop = ids.toSet();
    setState(() {
      _snapshotRows = [
        for (final r in _snapshotRows)
          if (!drop.contains((r['tdlib_chat_id'] as num?)?.toInt())) r,
      ];
    });
    _exitSelection();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ids.length == 1 ? 'Чат убран из архива' : 'Чаты убраны из архива',
        ),
      ),
    );
  }

  Future<void> _openChat({
    required int chatId,
    required String title,
    int? tgUserId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TelegramConversationScreen(
          chatId: chatId,
          title: title,
          tgUserId: tgUserId,
        ),
      ),
    );
  }

  List<_ArchiveRow> _rows(TelegramTdlibService svc) {
    final live = svc.hubArchiveChats;
    if (svc.phase == TdlibAuthPhase.ready && live.isNotEmpty) {
      return [
        for (final c in live)
          _ArchiveRow(
            chatId: c.chatId,
            title: c.title,
            tgUserId: (!c.isGroup && !c.isChannel && c.userId > 0)
                ? c.userId
                : null,
            photoPath: c.photoLocalPath,
            photoBytes: c.photoMinithumbnailBytes,
            lastText: c.lastMessageText,
            lastDate: c.lastMessageDate,
            unread: c.unreadCount,
            readStatus: c.lastMessageReadStatus,
            muted: svc.isChatMuted(c.chatId),
          ),
      ];
    }
    // Soft-blend: live empty / not ready → durable snapshot.
    return [
      for (final r in _snapshotRows)
        if ((r['tdlib_chat_id'] as num?)?.toInt() != null)
          _ArchiveRow(
            chatId: (r['tdlib_chat_id'] as num).toInt(),
            title: r['title']?.toString() ?? 'Чат',
            tgUserId: (r['tdlib_user_id'] as num?)?.toInt(),
            photoPath: r['tdlib_photo_path']?.toString(),
            photoBytes: r['tdlib_photo_bytes'] is List<int>
                ? r['tdlib_photo_bytes'] as List<int>
                : null,
            lastText: () {
              final lm = r['last_message'];
              if (lm is Map) return lm['body']?.toString() ?? '';
              return '';
            }(),
            lastDate: () {
              final lm = r['last_message'];
              if (lm is! Map) return 0;
              final created = DateTime.tryParse(
                lm['created_at']?.toString() ?? '',
              );
              if (created != null) {
                return created.millisecondsSinceEpoch ~/ 1000;
              }
              return 0;
            }(),
            unread: chatAsInt(r['unread_count']) ?? 0,
            readStatus: () {
              final lm = r['last_message'];
              if (lm is! Map) return null;
              final s = lm['read_status']?.toString();
              return (s != null && s.isNotEmpty) ? s : null;
            }(),
            muted: r['notifications_enabled'] == false,
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final svc = ref.watch(telegramTdlibServiceProvider);
    final chats = _rows(svc);

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: _selectionMode ? '${_selected.length}' : 'Архив чатов',
        automaticallyImplyLeading: !_selectionMode,
        leading: _selectionMode
            ? IconButton(
                tooltip: 'Отменить выбор',
                onPressed: _exitSelection,
                icon: const Icon(LucideIcons.x),
              )
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  tooltip: 'Убрать из архива',
                  onPressed: _selected.isEmpty
                      ? null
                      : () => unawaited(_unarchiveSelected()),
                  icon: const Icon(LucideIcons.archive_restore),
                ),
              ]
            : null,
      ),
      body: chats.isEmpty
          ? Center(
              child: Text(
                'Нет архивных чатов',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          : ListView.builder(
              itemCount: chats.length,
              itemBuilder: (context, index) {
                final c = chats[index];
                final selected = _selected.contains(c.chatId);
                final unread = c.unread;
                final created = c.lastDate > 0
                    ? DateTime.fromMillisecondsSinceEpoch(c.lastDate * 1000)
                    : null;
                final unreadBadgeColor =
                    c.muted ? const Color(0xFFB0B0B0) : scheme.primary;
                return ListTile(
                  selected: selected,
                  selectedTileColor:
                      scheme.primaryContainer.withValues(alpha: 0.35),
                  leading: SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ChatAvatar(
                          name: c.title,
                          localFilePath: c.photoPath,
                          memoryBytes: c.photoBytes,
                          radius: 24,
                        ),
                        if (_selectionMode)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: selected
                                    ? scheme.primary
                                    : scheme.surface,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? scheme.primary
                                      : scheme.outline,
                                  width: 2,
                                ),
                              ),
                              child: selected
                                  ? Icon(
                                      LucideIcons.check,
                                      size: 12,
                                      color: scheme.onPrimary,
                                    )
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
                  title: Text(
                    c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight:
                          unread > 0 ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        if (c.readStatus != null) ...[
                          ChatMessageReadStatusIcon(
                            status: c.readStatus!,
                            color: scheme.onSurfaceVariant,
                            size: 15,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            c.lastText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (created != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            formatChatHubLastMessageTime(created),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.72),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: unread > 0
                      ? CircleAvatar(
                          radius: 10,
                          backgroundColor: unreadBadgeColor,
                          child: Text(
                            '$unread',
                            style: TextStyle(
                              color:
                                  c.muted ? scheme.surface : scheme.onPrimary,
                              fontSize: 11,
                            ),
                          ),
                        )
                      : null,
                  onTap: () {
                    if (_selectionMode) {
                      _toggle(c.chatId);
                    } else {
                      unawaited(
                        _openChat(
                          chatId: c.chatId,
                          title: c.title,
                          tgUserId: c.tgUserId,
                        ),
                      );
                    }
                  },
                  onLongPress: () => _toggle(c.chatId),
                );
              },
            ),
    );
  }
}

class _ArchiveRow {
  const _ArchiveRow({
    required this.chatId,
    required this.title,
    this.tgUserId,
    this.photoPath,
    this.photoBytes,
    this.lastText = '',
    this.lastDate = 0,
    this.unread = 0,
    this.readStatus,
    this.muted = false,
  });

  final int chatId;
  final String title;
  final int? tgUserId;
  final String? photoPath;
  final List<int>? photoBytes;
  final String lastText;
  final int lastDate;
  final int unread;
  final String? readStatus;
  final bool muted;
}
