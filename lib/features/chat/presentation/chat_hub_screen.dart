import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../chat/data/chat_offline_sync.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/chat_hub_tab_order_storage.dart';
import '../data/chat_unread_providers.dart';
import '../data/familychat_realtime.dart';
import 'chat_conversation_screen.dart';
import 'chat_thread_avatars.dart';
import 'create_group_screen.dart';
import 'friend_invite_flow.dart';
import 'widgets/chat_message_read_status_icon.dart';

enum _ChatFilter { all, family, dm, group, friends }

class ChatHubScreen extends ConsumerStatefulWidget {
  const ChatHubScreen({super.key});

  @override
  ConsumerState<ChatHubScreen> createState() => ChatHubScreenState();
}

class ChatHubScreenState extends ConsumerState<ChatHubScreen>
    with SingleTickerProviderStateMixin {
  static const _defaultFilters = <_ChatFilter>[
    _ChatFilter.all,
    _ChatFilter.family,
    _ChatFilter.dm,
    _ChatFilter.group,
    _ChatFilter.friends,
  ];

  late final TabController _tabController;
  List<_ChatFilter> _filters = List<_ChatFilter>.of(_defaultFilters);
  List<Map<String, dynamic>> _threads = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  bool _loading = true;
  bool _searchVisible = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  /// Обновить список чатов (например при возврате на вкладку).
  Future<void> refresh({bool silent = true}) => _load(silent: silent);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _filters.length, vsync: this);
    FamilyChatRealtime.instance.addListener(_onRealtime);
    ChatOfflineSync.instance.addListener(_onOfflineSync);
    unawaited(_restoreTabOrder());
    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    ChatOfflineSync.instance.removeListener(_onOfflineSync);
    _searchController.dispose();
    super.dispose();
  }

  String _filterLabel(_ChatFilter filter) {
    return switch (filter) {
      _ChatFilter.all => 'Все',
      _ChatFilter.family => 'Семья',
      _ChatFilter.dm => 'Личные',
      _ChatFilter.group => 'Группы',
      _ChatFilter.friends => 'Друзья',
    };
  }

  String _filterKey(_ChatFilter filter) => filter.name;

  _ChatFilter? _filterFromKey(String key) {
    for (final f in _ChatFilter.values) {
      if (f.name == key) return f;
    }
    return null;
  }

  Future<void> _restoreTabOrder() async {
    final saved = await ChatHubTabOrderStorage.load();
    if (!mounted || saved == null || saved.isEmpty) return;
    final restored = <_ChatFilter>[];
    for (final key in saved) {
      final filter = _filterFromKey(key);
      if (filter != null && !restored.contains(filter)) {
        restored.add(filter);
      }
    }
    for (final filter in _defaultFilters) {
      if (!restored.contains(filter)) restored.add(filter);
    }
    if (restored.length != _defaultFilters.length) return;
    final same = restored.length == _filters.length &&
        List.generate(restored.length, (i) => restored[i] == _filters[i])
            .every((ok) => ok);
    if (same) return;
    setState(() => _filters = restored);
  }

  Future<void> _persistTabOrder() async {
    await ChatHubTabOrderStorage.save(_filters.map(_filterKey).toList());
  }

  void _onReorderTabs(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final selected = _filters[_tabController.index];
    setState(() {
      final item = _filters.removeAt(oldIndex);
      _filters.insert(newIndex, item);
    });
    final nextIndex = _filters.indexOf(selected);
    if (nextIndex >= 0 && _tabController.index != nextIndex) {
      _tabController.index = nextIndex;
    }
    unawaited(_persistTabOrder());
  }

  void _onOfflineSync() {
    if (!mounted) return;
    if (ChatOfflineSync.instance.isOnline) {
      unawaited(_load(silent: true));
    }
  }

  void _applyMembers(List<Map<String, dynamic>> members) {
    final byUserId = <int, Map<String, dynamic>>{};
    for (final m in members) {
      final uid = m['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null) continue;
      byUserId[userId] = m;
    }
    _memberByUserId
      ..clear()
      ..addAll(byUserId);
  }

  Future<void> _hydrateFromCache() async {
    final cachedThreads = await FamilyChatLocalCache.readChatThreads();
    if (cachedThreads == null || cachedThreads.isEmpty || !mounted) return;
    final cachedMembers = await FamilyChatLocalCache.readChatMembers();
    setState(() {
      _threads = _sortedThreads(cachedThreads);
      if (cachedMembers != null) {
        _applyMembers(cachedMembers);
      }
      _loading = false;
    });
  }

  void _onRealtime(Map<String, dynamic> event) {
    final ev = event['event']?.toString();
    if (ev == 'chat_message' ||
        ev == 'chat_messages_read' ||
        ev == 'chat_refresh' ||
        ev == 'chat_messages_deleted' ||
        ev == 'chat_message_reactions') {
      unawaited(_load(silent: true));
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      await _hydrateFromCache();
      if (_threads.isEmpty && mounted) {
        setState(() => _loading = true);
      }
    }
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final results = await Future.wait([
        repo.chatThreads(),
        repo.members(),
      ]);
      final list = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await FamilyChatLocalCache.saveChatThreads(list);
      await FamilyChatLocalCache.saveChatMembers(members);
      if (!mounted) return;
      final sorted = _sortedThreads(list);
      final sameThreads = _threadsFingerprint(_threads) ==
          _threadsFingerprint(sorted);
      if (sameThreads && !_loading) {
        setState(() => _applyMembers(members));
        invalidateChatUnreadTotal(ref);
        unawaited(ChatOfflineSync.instance.refreshOnline(repo));
        return;
      }
      setState(() {
        _threads = sorted;
        _applyMembers(members);
        _loading = false;
      });
      invalidateChatUnreadTotal(ref);
      unawaited(ChatOfflineSync.instance.refreshOnline(repo));
    } catch (_) {
      if (!mounted) return;
      if (_threads.isEmpty) {
        await _hydrateFromCache();
      }
      setState(() {
        _loading = false;
      });
    }
  }

  String _threadsFingerprint(List<Map<String, dynamic>> threads) {
    return threads.map((t) {
      final last = t['last_message'] as Map<String, dynamic>?;
      return '${t['id']}|${t['unread_count']}|${last?['id']}|${t['title']}|${t['custom_title']}';
    }).join(';');
  }

  int? _dmPeerUserId(Map<String, dynamic> thread) {
    final kind = thread['kind']?.toString();
    if (kind != 'dm' && kind != 'friend_dm') return null;
    final raw = thread['peer_user_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  String? _dmAvatarUrl(Map<String, dynamic> thread) {
    final fromThread = thread['peer_avatar_url']?.toString().trim();
    if (fromThread != null && fromThread.isNotEmpty) return fromThread;
    final peerId = _dmPeerUserId(thread);
    if (peerId == null) return null;
    final member = _memberByUserId[peerId];
    final url = member?['avatar_url']?.toString().trim();
    if (url == null || url.isEmpty) return null;
    return url;
  }

  String _avatarName(Map<String, dynamic> thread) {
    final peerId = _dmPeerUserId(thread);
    if (peerId != null) {
      final member = _memberByUserId[peerId];
      final display = member?['display_name']?.toString().trim();
      if (display != null && display.isNotEmpty) return display;
    }
    return thread['title']?.toString() ?? 'Чат';
  }

  List<Map<String, dynamic>> _sortedThreads(List<Map<String, dynamic>> threads) {
    final sorted = List<Map<String, dynamic>>.from(threads);
    sorted.sort((a, b) => _lastActivityAt(b).compareTo(_lastActivityAt(a)));
    return sorted;
  }

  DateTime _lastActivityAt(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    return DateTime.tryParse(last?['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool _isBirthdayCelebration(Map<String, dynamic> thread) {
    return thread['is_birthday_celebration'] == true;
  }

  bool _matchesFilter(Map<String, dynamic> thread, _ChatFilter filter) {
    final kind = thread['kind']?.toString() ?? '';
    return switch (filter) {
      _ChatFilter.all => true,
      _ChatFilter.family => kind == 'family' || _isBirthdayCelebration(thread),
      _ChatFilter.dm => kind == 'dm',
      _ChatFilter.group => kind == 'group' && !_isBirthdayCelebration(thread),
      _ChatFilter.friends => kind == 'friend_dm',
    };
  }

  List<Map<String, dynamic>> _filteredBy(_ChatFilter filter) {
    final q = _searchQuery.trim().toLowerCase();
    return _threads.where((t) {
      if (!_matchesFilter(t, filter)) return false;
      if (q.isEmpty) return true;
      final title = t['title']?.toString().toLowerCase() ?? '';
      final defaultTitle = t['default_title']?.toString().toLowerCase() ?? '';
      return title.contains(q) || defaultTitle.contains(q);
    }).toList();
  }

  String _preview(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    if (last == null) return 'Нет сообщений';
    final body = last['body']?.toString() ?? '';
    if (body.isNotEmpty) return body;
    final atts = (last['attachments'] as List?) ?? [];
    if (atts.isNotEmpty) return 'Вложение';
    return 'Сообщение';
  }

  /// Статус только для своих последних сообщений (сервер кладёт read_status).
  String? _lastMessageReadStatus(Map<String, dynamic>? last) {
    if (last == null || last['is_system'] == true) return null;
    final status = last['read_status']?.toString().trim();
    if (status == null || status.isEmpty) return null;
    return status;
  }

  List<int> _participantIdsOf(Map<String, dynamic> thread) {
    return (thread['participant_user_ids'] as List?)
            ?.map((e) => e is int ? e : int.tryParse('$e'))
            .whereType<int>()
            .toList() ??
        const [];
  }

  Future<void> _openThread(Map<String, dynamic> thread) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatConversationScreen(
          threadId: thread['id'] as int,
          title: thread['title']?.toString() ?? 'Чат',
          defaultTitle: thread['default_title']?.toString() ??
              thread['title']?.toString() ??
              'Чат',
          customTitle: thread['custom_title']?.toString() ?? '',
          kind: thread['kind']?.toString() ?? 'family',
          peerUserId: thread['peer_user_id'] as int?,
          initialHasLeft: thread['has_left'] == true,
          initialCanRejoin: thread['can_rejoin'] == true,
          initialCanLeave: thread['can_leave'] == true,
          initialParticipantUserIds: _participantIdsOf(thread),
          initialIsBirthdayCelebration: thread['is_birthday_celebration'] == true,
          initialPeerAvatarUrl: _dmAvatarUrl(thread),
          initialCanSend: thread['can_send'] != false,
          expectedLastMessageId: () {
            final last = thread['last_message'];
            if (last is Map) {
              final id = last['id'];
              if (id is int) return id;
              return int.tryParse('$id');
            }
            return null;
          }(),
        ),
      ),
    );
    await _load();
  }

  Future<void> createGroup() async {
    final created = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
    );
    if (created != null && mounted) {
      await _openThread(created);
    }
    await _load();
  }

  Future<void> openCreateMenu({required bool hasIndividualPremium}) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('Группа'),
              onTap: () => Navigator.pop(ctx, 'group'),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Контакт'),
              subtitle: Text(
                hasIndividualPremium
                    ? 'Личный чат вне семьи'
                    : 'Нужен Individual Premium',
              ),
              onTap: () => Navigator.pop(ctx, 'contact'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'group') {
      await createGroup();
      return;
    }
    await runFriendInviteFlow(
      context,
      ref.read(familychatRepositoryProvider),
      hasIndividualPremium: hasIndividualPremium,
    );
  }

  String _emptyLabel(_ChatFilter filter) {
    if (_searchQuery.trim().isNotEmpty) return 'Чаты не найдены';
    return switch (filter) {
      _ChatFilter.all => 'Нет чатов',
      _ChatFilter.family => 'Нет семейных чатов',
      _ChatFilter.dm => 'Нет личных чатов',
      _ChatFilter.group => 'Нет групповых чатов',
      _ChatFilter.friends => 'Нет контактов',
    };
  }

  Widget _buildThreadList(_ChatFilter filter) {
    final timeFmt = DateFormat('dd.MM HH:mm');
    final filtered = _filteredBy(filter);

    if (_loading) {
      return const DeferredPlaceholder(child: ChatHubListSkeleton());
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: filtered.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                Center(child: Text(_emptyLabel(filter))),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: filtered.length,
              itemBuilder: (context, i) {
                final t = filtered[i];
                final title = t['title']?.toString() ?? 'Чат';
                final unread = t['unread_count'] as int? ?? 0;
                final last = t['last_message'] as Map<String, dynamic>?;
                final lastStatus = _lastMessageReadStatus(last);
                final created = last != null
                    ? DateTime.tryParse(last['created_at']?.toString() ?? '')
                    : null;
                final isBirthday = _isBirthdayCelebration(t);
                final avatarAsset = chatThreadAvatarAsset(
                  kind: t['kind']?.toString() ?? '',
                  isBirthdayCelebration: isBirthday,
                );
                final theme = Theme.of(context);
                final scheme = theme.colorScheme;
                final previewStyle = theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                );
                final timeStyle = theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.72),
                );

                return ListTile(
                  leading: ChatAvatar(
                    name: _avatarName(t),
                    avatarUrl: avatarAsset != null ? null : _dmAvatarUrl(t),
                    userId: avatarAsset != null ? null : _dmPeerUserId(t),
                    assetPath: avatarAsset,
                    radius: 24,
                  ),
                  title: Text(
                    title,
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
                                  _preview(t),
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
                            timeFmt.format(created.toLocal()),
                            style: timeStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: unread > 0
                      ? CircleAvatar(
                          radius: 10,
                          backgroundColor: scheme.primary,
                          child: Text(
                            '$unread',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        )
                      : null,
                  onTap: () => _openThread(t),
                );
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      children: [
        if (_searchVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: 'Поиск по названию чата',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        icon: const Icon(Icons.clear),
                      )
                    : null,
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
        Material(
          color: scheme.surface,
          child: _ChatFilterTabBar(
            filters: _filters,
            controller: _tabController,
            labelOf: _filterLabel,
            onReorder: _onReorderTabs,
            labelStyle: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: theme.textTheme.titleSmall,
            dividerColor: scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _filters.map(_buildThreadList).toList(),
          ),
        ),
      ],
    );
  }
}

class _ChatFilterTabBar extends StatelessWidget {
  const _ChatFilterTabBar({
    required this.filters,
    required this.controller,
    required this.labelOf,
    required this.onReorder,
    this.labelStyle,
    this.unselectedLabelStyle,
    this.dividerColor,
  });

  final List<_ChatFilter> filters;
  final TabController controller;
  final String Function(_ChatFilter filter) labelOf;
  final void Function(int oldIndex, int newIndex) onReorder;
  final TextStyle? labelStyle;
  final TextStyle? unselectedLabelStyle;
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedColor = scheme.primary;
    final unselectedColor = scheme.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 46,
          child: AnimatedBuilder(
            animation: Listenable.merge([
              controller,
              if (controller.animation != null) controller.animation!,
            ]),
            builder: (context, _) {
              final animValue =
                  controller.animation?.value ?? controller.index.toDouble();
              return ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final t = Curves.easeInOut.transform(animation.value);
                      return Material(
                        elevation: 2 + 4 * t,
                        color: scheme.surface,
                        shadowColor: scheme.shadow.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(10),
                        child: child,
                      );
                    },
                  );
                },
                onReorder: onReorder,
                itemCount: filters.length,
                itemBuilder: (context, index) {
                  final filter = filters[index];
                  final selected = animValue.round() == index;
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey(filter),
                    index: index,
                    child: IntrinsicWidth(
                      child: InkWell(
                        onTap: () {
                          if (controller.index != index) {
                            controller.animateTo(index);
                          }
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                width: 3,
                                color: selected
                                    ? selectedColor
                                    : Colors.transparent,
                              ),
                            ),
                          ),
                          child: Text(
                            labelOf(filter),
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            style: (selected
                                    ? labelStyle
                                    : unselectedLabelStyle)
                                ?.copyWith(
                              color: selected
                                  ? selectedColor
                                  : unselectedColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        Divider(
          height: 1,
          thickness: 1,
          color: dividerColor,
        ),
      ],
    );
  }
}
