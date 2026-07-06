import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers/app_providers.dart';
import '../../profile/presentation/widgets/chat_avatar.dart';
import '../data/familychat_realtime.dart';
import 'chat_conversation_screen.dart';
import 'create_group_screen.dart';

enum _ChatFilter { all, family, dm, group }

class ChatHubScreen extends ConsumerStatefulWidget {
  const ChatHubScreen({super.key});

  @override
  ConsumerState<ChatHubScreen> createState() => ChatHubScreenState();
}

class ChatHubScreenState extends ConsumerState<ChatHubScreen> {
  _ChatFilter _filter = _ChatFilter.all;
  List<Map<String, dynamic>> _threads = [];
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

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    _load();
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    _searchController.dispose();
    super.dispose();
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
    if (!silent) setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).chatThreads();
      if (!mounted) return;
      setState(() {
        _threads = _sortedThreads(list);
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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

  List<Map<String, dynamic>> get _filtered {
    final q = _searchQuery.trim().toLowerCase();
    return _threads.where((t) {
      final kind = t['kind']?.toString() ?? '';
      final kindOk = switch (_filter) {
        _ChatFilter.all => true,
        _ChatFilter.family => kind == 'family',
        _ChatFilter.dm => kind == 'dm',
        _ChatFilter.group => kind == 'group',
      };
      if (!kindOk) return false;
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

  Future<void> _openThread(Map<String, dynamic> thread) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatConversationScreen(
          threadId: thread['id'] as int,
          title: thread['title']?.toString() ?? 'Чат',
          defaultTitle: thread['default_title']?.toString() ?? thread['title']?.toString() ?? 'Чат',
          customTitle: thread['custom_title']?.toString() ?? '',
          kind: thread['kind']?.toString() ?? 'family',
          peerUserId: thread['peer_user_id'] as int?,
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

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('dd.MM HH:mm');

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
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Все'),
                selected: _filter == _ChatFilter.all,
                onSelected: (_) => setState(() => _filter = _ChatFilter.all),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Семья'),
                selected: _filter == _ChatFilter.family,
                onSelected: (_) => setState(() => _filter = _ChatFilter.family),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Личные'),
                selected: _filter == _ChatFilter.dm,
                onSelected: (_) => setState(() => _filter = _ChatFilter.dm),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Группы'),
                selected: _filter == _ChatFilter.group,
                onSelected: (_) => setState(() => _filter = _ChatFilter.group),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _filtered.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 120),
                            Center(
                              child: Text(
                                _searchQuery.trim().isNotEmpty
                                    ? 'Чаты не найдены'
                                    : 'Нет чатов',
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          itemCount: _filtered.length,
                          itemBuilder: (context, i) {
                            final t = _filtered[i];
                            final title = t['title']?.toString() ?? 'Чат';
                            final unread = t['unread_count'] as int? ?? 0;
                            final last = t['last_message'] as Map<String, dynamic>?;
                            final created = last != null
                                ? DateTime.tryParse(last['created_at']?.toString() ?? '')
                                : null;
                            return ListTile(
                              leading: ChatAvatar(name: title, radius: 24),
                              title: Text(title),
                              subtitle: Text(
                                _preview(t),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  if (created != null)
                                    Text(
                                      timeFmt.format(created.toLocal()),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  if (unread > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: CircleAvatar(
                                        radius: 10,
                                        backgroundColor:
                                            Theme.of(context).colorScheme.primary,
                                        child: Text(
                                          '$unread',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              onTap: () => _openThread(t),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }
}
