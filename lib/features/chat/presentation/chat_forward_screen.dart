import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../../telegram_tdlib/telegram_match_store.dart';
import '../../telegram_tdlib/telegram_tdlib_providers.dart';
import '../../telegram_tdlib/telegram_tdlib_service.dart';
import '../data/chat_hub_folders.dart';
import '../data/chat_local_reads.dart';
import '../data/chat_message_preview.dart';
import '../data/chat_realtime_utils.dart';
import 'widgets/chat_thread_select_tile.dart';

/// Выбор чатов для пересылки сообщений (FC + Telegram при подключении).
class ChatForwardScreen extends ConsumerStatefulWidget {
  const ChatForwardScreen({
    super.key,
    required this.sourceThreadId,
    required this.messageIds,
  });

  final int sourceThreadId;
  final List<int> messageIds;

  /// Returns `true` when forward succeeded to at least one target.
  static Future<bool?> open(
    BuildContext context, {
    required int sourceThreadId,
    required List<int> messageIds,
  }) {
    if (messageIds.isEmpty) return Future<bool?>.value();
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChatForwardScreen(
          sourceThreadId: sourceThreadId,
          messageIds: messageIds,
        ),
      ),
    );
  }

  @override
  ConsumerState<ChatForwardScreen> createState() => _ChatForwardScreenState();
}

class _ChatForwardScreenState extends ConsumerState<ChatForwardScreen> {
  List<Map<String, dynamic>> _fcThreads = [];
  /// All FC threads including source (for linked TG group exclusion).
  List<Map<String, dynamic>> _fcThreadsAll = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  Map<int, TelegramMatch> _tdlibMatches = {};
  /// Selection keys: `t:<fcThreadId>` / `tg:<tdlibChatId>`.
  final _selected = <String>{};
  bool _loading = true;
  bool _sending = false;
  bool _searchVisible = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_reloadMatches());
    unawaited(_hydrateFromLocal());
    unawaited(_refreshFromNetwork());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reloadMatches() async {
    final matches = await TelegramMatchStore.instance.loadAll();
    if (!mounted) return;
    setState(() => _tdlibMatches = matches);
  }

  List<Map<String, dynamic>> _withoutSource(List<Map<String, dynamic>> list) {
    return list
        .where((t) => chatAsInt(t['id']) != widget.sourceThreadId)
        .toList();
  }

  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> threads) {
    final sorted = List<Map<String, dynamic>>.from(threads);
    sorted.sort((a, b) {
      DateTime at(Map<String, dynamic> t) {
        final last = t['last_message'] as Map<String, dynamic>?;
        return DateTime.tryParse(last?['created_at']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }

      return at(b).compareTo(at(a));
    });
    return sorted;
  }

  void _applyMembers(List<Map<String, dynamic>> members) {
    final byUserId = <int, Map<String, dynamic>>{};
    for (final member in members) {
      final uid = member['user_id'];
      final userId = uid is int ? uid : int.tryParse('$uid');
      if (userId == null) continue;
      byUserId[userId] = member;
    }
    _memberByUserId
      ..clear()
      ..addAll(byUserId);
  }

  Future<void> _hydrateFromLocal() async {
    try {
      final threads = await ChatLocalReads.threads();
      final members = await ChatLocalReads.members();
      if (!mounted) return;
      if (threads.isEmpty && members.isEmpty) return;
      setState(() {
        if (threads.isNotEmpty) {
          _fcThreadsAll = threads;
          _fcThreads = _sorted(_withoutSource(threads));
          _loading = false;
        }
        if (members.isNotEmpty) _applyMembers(members);
      });
    } catch (_) {}
  }

  Future<void> _refreshFromNetwork() async {
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final results = await Future.wait<dynamic>([
        repo.chatThreads(),
        repo.members(),
      ]);
      final list = (results[0] as List).cast<Map<String, dynamic>>();
      final members = (results[1] as List).cast<Map<String, dynamic>>();
      await ChatLocalReads.saveThreadsAndMembers(
        threads: list,
        members: members,
      );
      if (!mounted) return;
      setState(() {
        _fcThreadsAll = list;
        _fcThreads = _sorted(_withoutSource(list));
        _applyMembers(members);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Set<int> get _linkedTelegramGroupChatIds {
    final out = <int>{};
    for (final t in _fcThreadsAll) {
      if (t['kind']?.toString() != 'group') continue;
      final tg = t['telegram'];
      if (tg is! Map || tg['linked'] != true) continue;
      final id = (tg['tg_chat_id'] as num?)?.toInt() ??
          int.tryParse('${tg['tg_chat_id'] ?? ''}');
      if (id != null && id != 0) out.add(id);
    }
    return out;
  }

  Set<int> get _matchedTgUserIds => {
        for (final m in _tdlibMatches.values)
          if (m.tgUserId > 0) m.tgUserId,
      };

  List<Map<String, dynamic>> _telegramEntries(TelegramTdlibService svc) {
    if (svc.phase != TdlibAuthPhase.ready) return const [];
    final linkedGroups = _linkedTelegramGroupChatIds;
    final matchedUsers = _matchedTgUserIds;
    final out = <Map<String, dynamic>>[];
    for (final c in svc.hubChats) {
      if (svc.isSavedMessagesChat(c.chatId)) continue;
      final isPrivate = !c.isGroup && !c.isChannel;
      if (isPrivate && matchedUsers.contains(c.userId)) continue;
      if (linkedGroups.contains(c.chatId)) continue;
      final created = c.lastMessageDate > 0
          ? DateTime.fromMillisecondsSinceEpoch(c.lastMessageDate * 1000)
              .toIso8601String()
          : null;
      out.add({
        'id': -c.chatId.abs(),
        'kind': 'tdlib_chat',
        'title': c.title,
        'tdlib_chat_id': c.chatId,
        if (!c.isGroup && !c.isChannel) 'tdlib_user_id': c.userId,
        'tdlib_photo_path': c.photoLocalPath,
        'tdlib_photo_bytes': c.photoMinithumbnailBytes,
        'last_message': {
          'body': c.lastMessageText,
          if (created != null) 'created_at': created,
          if (c.lastMessageReadStatus != null)
            'read_status': c.lastMessageReadStatus,
          if (c.lastMessageOutgoing) 'is_mine': true,
        },
      });
    }
    return out;
  }

  String? _rowKey(Map<String, dynamic> row) =>
      ChatFolderMemberKey.forHubRow(row);

  List<Map<String, dynamic>> _mergedRows(TelegramTdlibService svc) {
    return _sorted([
      ..._fcThreads,
      ..._telegramEntries(svc),
    ]);
  }

  List<Map<String, dynamic>> _filteredRows(List<Map<String, dynamic>> rows) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return rows;
    return [
      for (final t in rows)
        if (ChatThreadSelectTile.titleOf(t, _memberByUserId)
            .toLowerCase()
            .contains(q))
          t,
    ];
  }

  List<int> get _selectedFcIds {
    final out = <int>[];
    for (final key in _selected) {
      if (!key.startsWith('t:')) continue;
      final id = int.tryParse(key.substring(2));
      if (id != null && id > 0) out.add(id);
    }
    return out;
  }

  List<int> get _selectedTgChatIds {
    final out = <int>[];
    for (final key in _selected) {
      if (!key.startsWith('tg:')) continue;
      final id = int.tryParse(key.substring(3));
      if (id != null && id != 0) out.add(id);
    }
    return out;
  }

  bool get _hasSelection => _selected.isNotEmpty;

  bool _allVisibleSelected(List<Map<String, dynamic>> visible) {
    if (visible.isEmpty) return false;
    for (final t in visible) {
      final key = _rowKey(t);
      if (key == null || !_selected.contains(key)) return false;
    }
    return true;
  }

  void _toggleSelectAll(List<Map<String, dynamic>> visible) {
    setState(() {
      if (_allVisibleSelected(visible)) {
        for (final t in visible) {
          final key = _rowKey(t);
          if (key != null) _selected.remove(key);
        }
      } else {
        for (final t in visible) {
          final key = _rowKey(t);
          if (key != null) _selected.add(key);
        }
      }
    });
  }

  void _toggle(Map<String, dynamic> row) {
    final key = _rowKey(row);
    if (key == null) return;
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchQuery = '';
        _searchController.clear();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadSourceMessages() async {
    final idSet = widget.messageIds.toSet();
    final rows = await ChatLocalReads.messages(widget.sourceThreadId);
    final found = <Map<String, dynamic>>[];
    for (final m in rows) {
      final id = chatAsInt(m['id']);
      if (id != null && idSet.contains(id)) {
        found.add(m);
      }
    }
    found.sort((a, b) {
      final ai = chatAsInt(a['id']) ?? 0;
      final bi = chatAsInt(b['id']) ?? 0;
      return ai.compareTo(bi);
    });
    if (found.length >= idSet.length) return found;

    // Fallback: pull a page from API if local cache missed some ids.
    try {
      final page = await ref.read(familychatRepositoryProvider).threadMessages(
            widget.sourceThreadId,
            limit: 100,
          );
      final byId = <int, Map<String, dynamic>>{
        for (final m in found)
          if (chatAsInt(m['id']) != null) chatAsInt(m['id'])!: m,
      };
      for (final m in page.messages) {
        final id = chatAsInt(m['id']);
        if (id != null && idSet.contains(id)) byId[id] = m;
      }
      return [
        for (final id in widget.messageIds)
          if (byId.containsKey(id)) byId[id]!,
      ];
    } catch (_) {
      return found;
    }
  }

  Future<void> _forwardTextsToTelegram(List<int> tgChatIds) async {
    if (tgChatIds.isEmpty) return;
    final svc = ref.read(telegramTdlibServiceProvider);
    if (!svc.isReady) {
      throw StateError('Telegram не подключён');
    }
    final messages = await _loadSourceMessages();
    for (final chatId in tgChatIds) {
      for (final msg in messages) {
        final text = chatMessagePreviewText(msg).trim();
        if (text.isEmpty) continue;
        await svc.sendText(chatId, text);
      }
    }
  }

  Future<void> _send() async {
    if (!_hasSelection || _sending) return;
    setState(() => _sending = true);
    final fcIds = _selectedFcIds;
    final tgIds = _selectedTgChatIds;
    try {
      if (fcIds.isNotEmpty) {
        await ref.read(familychatRepositoryProvider).forwardMessages(
              sourceThreadId: widget.sourceThreadId,
              messageIds: widget.messageIds,
              threadIds: fcIds,
            );
      }
      if (tgIds.isNotEmpty) {
        await _forwardTextsToTelegram(tgIds);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переслать')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tdlib = ref.watch(telegramTdlibServiceProvider);
    final merged = _mergedRows(tdlib);
    final visible = _filteredRows(merged);
    final showSend = _hasSelection;
    final allSelected = _allVisibleSelected(visible);

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Переслать',
        actions: [
          IconButton(
            tooltip: _searchVisible ? 'Закрыть поиск' : 'Поиск',
            onPressed: _toggleSearch,
            icon: Icon(_searchVisible ? LucideIcons.x : LucideIcons.search),
          ),
          TextButton(
            onPressed: visible.isEmpty ? null : () => _toggleSelectAll(visible),
            child: Text(allSelected ? 'Снять все' : 'Выбрать все'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_searchVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Поиск чата',
                  prefixIcon: const Icon(LucideIcons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          icon: const Icon(LucideIcons.x),
                        )
                      : null,
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
              ),
            ),
          Expanded(
            child: _loading
                ? const DeferredPlaceholder(
                    child: Center(child: CircularProgressIndicator()),
                  )
                : visible.isEmpty
                    ? Center(
                        child: Text(
                          _searchQuery.trim().isNotEmpty
                              ? 'Чаты не найдены'
                              : 'Нет доступных чатов',
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: showSend ? 88 : 16),
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final t = visible[i];
                          final key = _rowKey(t);
                          if (key == null) return const SizedBox.shrink();
                          return ChatThreadSelectTile(
                            thread: t,
                            selected: _selected.contains(key),
                            memberByUserId: _memberByUserId,
                            onTap: () => _toggle(t),
                          );
                        },
                      ),
          ),
        ],
      ),
      bottomNavigationBar: showSend
          ? Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 3,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: FilledButton(
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _selected.length == 1
                                ? 'Переслать'
                                : 'Переслать в ${_selected.length}',
                          ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
