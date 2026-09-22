import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_actions_scope.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/providers/app_providers.dart';
import '../../profile/presentation/telegram_settings_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/chat_hub_last_message_time.dart';
import '../data/chat_local_reads.dart';
import '../data/chat_message_preview.dart';
import '../data/chat_realtime_utils.dart';
import '../data/chat_sync_service.dart';
import 'chat_conversation_screen.dart';
import 'widgets/chat_message_read_status_icon.dart';

/// Список чатов Telegram (Secretary) для сегмента «ТГ» в Chat Hub.
///
/// Как обычные чаты: UI из локального кэша, сервер — фоновая синхронизация.
class TelegramChatsPane extends ConsumerStatefulWidget {
  const TelegramChatsPane({
    super.key,
    required this.hasIndividualPremium,
    this.telegramConnected = false,
    this.telegramGrace = false,
  });

  final bool hasIndividualPremium;
  final bool telegramConnected;
  final bool telegramGrace;

  @override
  ConsumerState<TelegramChatsPane> createState() => _TelegramChatsPaneState();
}

class _TelegramChatsPaneState extends ConsumerState<TelegramChatsPane> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;
  bool _syncing = false;
  String? _error;
  StreamSubscription<List<Map<String, dynamic>>>? _localSub;

  bool get _tgEnabled =>
      widget.hasIndividualPremium &&
      (widget.telegramConnected || widget.telegramGrace);

  @override
  void initState() {
    super.initState();
    if (widget.hasIndividualPremium &&
        !widget.telegramConnected &&
        !widget.telegramGrace) {
      unawaited(AppActions.refreshStatus());
    }
    _bindLocalAndSync();
  }

  @override
  void dispose() {
    unawaited(_localSub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TelegramChatsPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOff = !oldWidget.telegramConnected && !oldWidget.telegramGrace;
    final nowOn = widget.telegramConnected || widget.telegramGrace;
    if (wasOff && nowOn) {
      _bindLocalAndSync();
    }
  }

  void _bindLocalAndSync() {
    unawaited(_localSub?.cancel() ?? Future<void>.value());
    _localSub = null;

    if (!_tgEnabled) {
      setState(() {
        _loading = false;
        _chats = [];
        _error = null;
      });
      return;
    }

    if (ChatLocalStore.isSupported) {
      _localSub = ChatLocalStore.instance.watchTelegramChats().listen((chats) {
        if (!mounted) return;
        setState(() {
          _chats = chats;
          _loading = false;
          _error = null;
        });
      });
    } else {
      unawaited(() async {
        final local = await ChatLocalReads.telegramChats();
        if (!mounted) return;
        setState(() {
          _chats = local;
          _loading = local.isEmpty;
        });
      }());
    }

    unawaited(_syncFromServer());
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const TelegramSettingsScreen(),
      ),
    );
    if (!mounted) return;
    await AppActions.refreshStatus();
  }

  Future<void> _syncFromServer() async {
    if (!_tgEnabled) return;
    if (_syncing) return;
    setState(() {
      _syncing = true;
      if (_chats.isEmpty) _loading = true;
      _error = null;
    });
    try {
      if (ChatSyncService.isSupported) {
        await ChatSyncService.instance.syncTelegramChats();
        if (!ChatLocalStore.isSupported) {
          final local = await ChatLocalReads.telegramChats();
          if (!mounted) return;
          setState(() {
            _chats = local;
            _loading = false;
          });
        } else if (mounted) {
          setState(() => _loading = false);
        }
      } else {
        final list =
            await ref.read(familychatRepositoryProvider).telegramChats();
        await ChatLocalReads.saveTelegramChats(list);
        if (!mounted) return;
        setState(() {
          _chats = list;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // Keep local snapshot; only show error when nothing to show.
        if (_chats.isEmpty) _error = e.toString();
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _match(Map<String, dynamic> chat) async {
    final chatId = chat['id'] as int?;
    if (chatId == null) return;
    final repo = ref.read(familychatRepositoryProvider);
    List<Map<String, dynamic>> candidates = [];
    try {
      final members = await repo.members();
      candidates.addAll(members.cast<Map<String, dynamic>>());
    } catch (_) {}
    try {
      final friends = await repo.listFriends();
      for (final f in friends) {
        candidates.add({
          'user_id': f['user_id'] ?? f['peer_user_id'],
          'display_name': f['display_name'] ?? f['name'] ?? 'Друг',
          'avatar_url': f['avatar_url'],
          '_friend': true,
        });
      }
    } catch (_) {}

    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        if (candidates.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Нет членов семьи или друзей для связи'),
          );
        }
        return ListView(
          children: candidates.map((c) {
            final name = c['display_name']?.toString() ??
                c['name']?.toString() ??
                'Участник';
            final uid = c['user_id'] as int?;
            final avatarUrl = c['avatar_url']?.toString();
            return ListTile(
              leading: ChatAvatar(
                name: name,
                avatarUrl: avatarUrl,
                userId: uid,
                radius: 22,
              ),
              title: Text(name),
              subtitle: Text(c['_friend'] == true ? 'Друг' : 'Семья'),
              onTap: uid == null ? null : () => Navigator.pop(ctx, c),
            );
          }).toList(),
        );
      },
    );
    if (picked == null) return;
    final uid = picked['user_id'] as int?;
    if (uid == null) return;
    try {
      await repo.telegramMatchChat(chatId: chatId, userId: uid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Чат связан')),
      );
      await _syncFromServer();
      unawaited(ChatSyncService.instance.syncHub(force: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось связать: $e')),
      );
    }
  }

  String _displayTitle(Map<String, dynamic> c) {
    final title = c['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) return title;
    return 'Telegram';
  }

  int? _matchedUserId(Map<String, dynamic> c) {
    final raw = c['matched_user_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String? _avatarUrl(Map<String, dynamic> c) {
    final peer = c['peer_avatar_url']?.toString().trim();
    if (peer != null && peer.isNotEmpty) return peer;
    return null;
  }

  Map<String, dynamic>? _lastMessageOf(Map<String, dynamic> c) {
    final raw = c['last_message'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  String? _lastMessageReadStatus(Map<String, dynamic>? last) {
    if (last == null || last['is_system'] == true) return null;
    if (last['is_mine'] == false) return null;
    final status = last['read_status']?.toString().trim();
    if (status == null || status.isEmpty) return null;
    return status;
  }

  String? _timeLabel(Map<String, dynamic>? last) {
    if (last == null) return null;
    final raw = last['created_at']?.toString();
    if (raw == null || raw.isEmpty) return null;
    final dt = DateTime.tryParse(raw);
    if (dt == null) return null;
    return formatChatHubLastMessageTime(dt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.hasIndividualPremium) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.crown, size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                'Telegram-секретарь доступен с Individual Premium',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      );
    }
    if (!widget.telegramConnected && !widget.telegramGrace) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.send, size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                'Подключите Telegram Business-бота',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('Открыть настройки'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading && _chats.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _chats.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _syncFromServer,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }
    if (_chats.isEmpty) {
      return Center(
        child: Text(
          'Пока нет чатов Telegram.\nНапишите боту или дождитесь входящих.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _syncFromServer,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
        itemCount: _chats.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final c = _chats[i];
          final title = _displayTitle(c);
          final last = _lastMessageOf(c);
          final preview = chatMessagePreviewText(last);
          final timeLabel = _timeLabel(last);
          final unread = chatAsInt(c['unread_count']) ?? 0;
          final canMatch = c['can_match'] == true;
          final matchedUid = _matchedUserId(c);
          final avatarUrl = _avatarUrl(c);
          final readStatus = _lastMessageReadStatus(last);
          final threadId = chatAsInt(c['thread_id']) ??
              chatAsInt(c['matched_thread_id']) ??
              chatAsInt(c['fc_thread_id']);
          final scheme = theme.colorScheme;
          final previewStyle = theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          );

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: ChatAvatar(
              name: title,
              avatarUrl: avatarUrl,
              userId: matchedUid,
              radius: 26,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (timeLabel != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    timeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (readStatus != null) ...[
                          ChatMessageReadStatusIcon(
                            status: readStatus,
                            color: scheme.onSurfaceVariant,
                            size: 15,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: previewStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (canMatch)
                    IconButton(
                      tooltip: 'Связать с FamilyChat',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(LucideIcons.link, size: 20),
                      onPressed: () => unawaited(_match(c)),
                    )
                  else if (unread > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            onTap: threadId == null
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChatConversationScreen(
                          threadId: threadId,
                          title: title,
                          kind: c['matched_thread_kind']?.toString() ??
                              'telegram',
                          defaultTitle: c['default_title']?.toString(),
                          customTitle: c['custom_title']?.toString() ?? '',
                          peerUserId: matchedUid,
                          initialPeerAvatarUrl: avatarUrl,
                          openedFromTelegramTab: true,
                          expectedLastMessageId: chatAsInt(last?['id']),
                        ),
                      ),
                    );
                  },
          );
        },
      ),
    );
  }
}
