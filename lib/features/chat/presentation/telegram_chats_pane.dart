import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../profile/presentation/telegram_settings_screen.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../../telegram_tdlib/presentation/telegram_conversation_screen.dart';
import '../../telegram_tdlib/tdlib_config.dart';
import '../../telegram_tdlib/telegram_match_store.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
import '../data/chat_hub_last_message_time.dart';
import 'widgets/chat_message_read_status_icon.dart';

/// Список чатов Telegram (TDLib) для сегмента «ТГ»: личные + группы.
class TelegramChatsPane extends ConsumerStatefulWidget {
  const TelegramChatsPane({
    super.key,
    required this.hasIndividualPremium,
    this.telegramConnected = false,
    this.telegramGrace = false,
    this.searchQuery = '',
  });

  final bool hasIndividualPremium;
  /// Kept for hub API compat; TDLib readiness comes from [telegramTdlibServiceProvider].
  final bool telegramConnected;
  final bool telegramGrace;
  final String searchQuery;

  @override
  ConsumerState<TelegramChatsPane> createState() => _TelegramChatsPaneState();
}

class _TelegramChatsPaneState extends ConsumerState<TelegramChatsPane> {
  Map<int, TelegramMatch> _matches = {};
  final _listScroll = ScrollController();
  Timer? _avatarPrefetchTimer;
  List<int> _lastAvatarPrefetchIds = const [];
  int _lastAvatarPrefetchEpoch = -1;
  Timer? _scrollBusyClearTimer;
  var _didInitialAvatarPrefetch = false;

  @override
  void initState() {
    super.initState();
    _listScroll.addListener(_onListScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(telegramTdlibServiceProvider).ensureStarted());
      unawaited(_reloadMatches());
    });
  }

  @override
  void dispose() {
    _avatarPrefetchTimer?.cancel();
    _scrollBusyClearTimer?.cancel();
    ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
    _listScroll.removeListener(_onListScroll);
    _listScroll.dispose();
    super.dispose();
  }

  void _onListScroll() {
    ref.read(telegramTdlibServiceProvider).setUiScrollBusy(true);
    _scrollBusyClearTimer?.cancel();
    _scrollBusyClearTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      ref.read(telegramTdlibServiceProvider).setUiScrollBusy(false);
    });
    _avatarPrefetchTimer?.cancel();
    _avatarPrefetchTimer = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      _scheduleVisibleAvatarPrefetch();
    });
  }

  void _scheduleVisibleAvatarPrefetch([List<TdlibChatPreview>? chats]) {
    final svc = ref.read(telegramTdlibServiceProvider);
    final list = chats ??
        svc.hubChats
            .where((c) =>
                c.isGroup ||
                c.isChannel ||
                !_matches.containsKey(c.userId))
            .where((c) {
              final q = widget.searchQuery.trim().toLowerCase();
              if (q.isEmpty) return true;
              return c.title.toLowerCase().contains(q) ||
                  c.lastMessageText.toLowerCase().contains(q);
            })
            .toList();
    if (list.isEmpty) return;
    if (svc.isUiScrollBusy) return;

    // Prefer soft minithumb rows (visible blur). Also enqueue chats that
    // already have a TDLib photo file id but no minithumb (initials tiles).
    final needSharp = <int>[];
    const rowExtent = 72.0;
    var first = 0;
    if (_listScroll.hasClients) {
      first = (_listScroll.offset / rowExtent).floor().clamp(0, list.length - 1);
    }
    for (final c in list.skip(first).take(24)) {
      final path = c.photoLocalPath?.trim() ?? '';
      if (path.isNotEmpty) continue;
      final hasMini =
          c.photoMinithumbnailBytes != null &&
          c.photoMinithumbnailBytes!.isNotEmpty;
      final hasPhotoId = c.photoFileId != null && c.photoFileId! > 0;
      if (!hasMini && !hasPhotoId) continue;
      needSharp.add(c.chatId);
      if (needSharp.length >= 12) break;
    }
    if (needSharp.isEmpty) return;
    if (!svc.readyForMedia) return;
    final epoch = svc.mediaReadyEpoch;
    if (needSharp.length == _lastAvatarPrefetchIds.length &&
        epoch == _lastAvatarPrefetchEpoch) {
      var same = true;
      for (var i = 0; i < needSharp.length; i++) {
        if (needSharp[i] != _lastAvatarPrefetchIds[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    _lastAvatarPrefetchIds = List<int>.from(needSharp);
    _lastAvatarPrefetchEpoch = epoch;
    svc.prefetchVisibleHubAvatars(needSharp);
  }

  Future<void> _reloadMatches() async {
    final all = await TelegramMatchStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _matches = all);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const TelegramSettingsScreen(),
      ),
    );
    if (!mounted) return;
    await ref.read(telegramTdlibServiceProvider).ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.hasIndividualPremium) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Telegram доступен с Individual Premium'),
        ),
      );
    }

    final svc = ref.watch(telegramTdlibServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    if (!TdlibConfig.isEnabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                !TdlibConfig.isSupportedPlatform
                    ? 'TDLib поддерживается на Android и iOS'
                    : 'Нет Telegram API credentials',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('Настройки Telegram'),
              ),
            ],
          ),
        ),
      );
    }

    if (svc.phase != TdlibAuthPhase.ready) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.send, size: 40, color: scheme.primary),
              const SizedBox(height: 12),
              const Text(
                'Подключите Telegram, чтобы видеть чаты здесь',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _openSettings,
                child: const Text('Подключить'),
              ),
            ],
          ),
        ),
      );
    }

    final q = widget.searchQuery.trim().toLowerCase();
    final chats = svc.hubChats
        .where((c) =>
            !svc.isSavedMessagesChat(c.chatId) &&
            (c.isGroup ||
                c.isChannel ||
                !_matches.containsKey(c.userId)))
        .where((c) {
          if (q.isEmpty) return true;
          return c.title.toLowerCase().contains(q) ||
              c.lastMessageText.toLowerCase().contains(q);
        })
        .toList();

    final previewStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final timeStyle = theme.textTheme.bodySmall?.copyWith(
      fontSize: 11,
      color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
    );

    // One-shot warm for first viewport — not on every rebuild.
    if (chats.isNotEmpty && !_didInitialAvatarPrefetch) {
      _didInitialAvatarPrefetch = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleVisibleAvatarPrefetch(chats);
      });
    }

    return RefreshIndicator(
      onRefresh: () async {
        await svc.refreshChatList();
        await _reloadMatches();
      },
      child: chats.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(
                  child: Text(
                    q.isNotEmpty
                        ? 'Чаты не найдены'
                        : 'Нет чатов Telegram',
                  ),
                ),
              ],
            )
          : NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollUpdateNotification) {
                  ref
                      .read(telegramTdlibServiceProvider)
                      .setUiScrollBusy(true);
                } else if (n is ScrollEndNotification) {
                  _scheduleVisibleAvatarPrefetch(chats);
                  _scrollBusyClearTimer?.cancel();
                  _scrollBusyClearTimer = Timer(
                    const Duration(milliseconds: 280),
                    () {
                      if (!mounted) return;
                      ref
                          .read(telegramTdlibServiceProvider)
                          .setUiScrollBusy(false);
                    },
                  );
                }
                return false;
              },
              child: ListView.builder(
              controller: _listScroll,
              cacheExtent: 480,
              itemCount: chats.length,
              itemBuilder: (context, i) {
                final c = chats[i];
                final unread = c.unreadCount;
                final muted = svc.isChatMuted(c.chatId);
                final created = c.lastMessageDate > 0
                    ? DateTime.fromMillisecondsSinceEpoch(
                        c.lastMessageDate * 1000,
                      )
                    : null;
                final lastStatus = c.lastMessageReadStatus;
                final unreadBadgeColor = muted
                    ? const Color(0xFFB0B0B0)
                    : scheme.primary;
                final match = (!c.isGroup && !c.isChannel && c.userId > 0)
                    ? _matches[c.userId]
                    : null;
                final fcAvatar = match?.avatarUrl.trim() ?? '';
                final useTgPhoto = fcAvatar.isEmpty;

                return ListTile(
                  leading: ChatAvatar(
                    name: c.title,
                    avatarUrl: useTgPhoto ? null : fcAvatar,
                    userId: match?.fcUserId,
                    localFilePath: useTgPhoto ? c.photoLocalPath : null,
                    memoryBytes:
                        useTgPhoto ? c.photoMinithumbnailBytes : null,
                    radius: 24,
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
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              if (lastStatus != null) ...[
                                ChatMessageReadStatusIcon(
                                  status: lastStatus,
                                  color: scheme.onSurfaceVariant,
                                  size: 15,
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: Text(
                                  c.lastMessageText,
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
                            formatChatHubLastMessageTime(created),
                            style: timeStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: unread > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: unreadBadgeColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: TextStyle(
                              color: muted
                                  ? scheme.surface
                                  : scheme.onPrimary,
                              fontSize: 12,
                            ),
                          ),
                        )
                      : null,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => TelegramConversationScreen(
                          chatId: c.chatId,
                          title: c.title,
                          tgUserId:
                              (c.isGroup || c.isChannel) ? null : c.userId,
                          fcUserId: match?.fcUserId,
                          peerAvatarUrl: fcAvatar,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            ),
    );
  }
}
