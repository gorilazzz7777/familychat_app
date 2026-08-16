import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/local_db/chat_local_store.dart';
import '../../../core/widgets/app_skeletons.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../data/chat_realtime_utils.dart';
import 'widgets/chat_thread_select_tile.dart';

/// Выбор чатов для пересылки сообщений.
class ChatForwardScreen extends ConsumerStatefulWidget {
  const ChatForwardScreen({
    super.key,
    required this.sourceThreadId,
    required this.messageIds,
  });

  final int sourceThreadId;
  final List<int> messageIds;

  static Future<List<int>?> open(
    BuildContext context, {
    required int sourceThreadId,
    required List<int> messageIds,
  }) {
    if (messageIds.isEmpty) return Future<List<int>?>.value();
    return Navigator.of(context).push<List<int>>(
      MaterialPageRoute<List<int>>(
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
  List<Map<String, dynamic>> _threads = [];
  final Map<int, Map<String, dynamic>> _memberByUserId = {};
  final _selected = <int>{};
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_hydrateFromLocal());
    unawaited(_refreshFromNetwork());
  }

  List<Map<String, dynamic>> _withoutSource(List<Map<String, dynamic>> list) {
    return list.where((t) => chatAsInt(t['id']) != widget.sourceThreadId).toList();
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
      var threads = <Map<String, dynamic>>[];
      var members = <Map<String, dynamic>>[];
      if (ChatLocalStore.isSupported) {
        final results = await Future.wait([
          ChatLocalStore.instance.readThreads(),
          ChatLocalStore.instance.readMembers(),
        ]);
        threads = results[0];
        members = results[1];
      }
      if (threads.isEmpty) {
        threads = await FamilyChatLocalCache.readChatThreads() ?? [];
      }
      if (members.isEmpty) {
        members = await FamilyChatLocalCache.readChatMembers() ?? [];
      }
      if (!mounted) return;
      if (threads.isEmpty && members.isEmpty) return;
      setState(() {
        if (threads.isNotEmpty) {
          _threads = _sorted(_withoutSource(threads));
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
      await ChatLocalStore.instance.replaceThreads(list);
      await ChatLocalStore.instance.replaceMembers(members);
      if (!mounted) return;
      setState(() {
        _threads = _sorted(_withoutSource(list));
        _applyMembers(members);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(familychatRepositoryProvider).forwardMessages(
            sourceThreadId: widget.sourceThreadId,
            messageIds: widget.messageIds,
            threadIds: _selected.toList(),
          );
      if (!mounted) return;
      Navigator.of(context).pop(_selected.toList());
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переслать')),
      );
    }
  }

  List<int> get _selectableThreadIds =>
      _threads.map(chatAsInt).whereType<int>().toList();

  bool get _allThreadsSelected {
    final ids = _selectableThreadIds;
    return ids.isNotEmpty && ids.every(_selected.contains);
  }

  void _toggleSelectAllThreads() {
    final ids = _selectableThreadIds;
    setState(() {
      if (_allThreadsSelected) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  void _toggle(int id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final showSend = _selected.isNotEmpty;

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Переслать',
        actions: [
          TextButton(
            onPressed:
                _selectableThreadIds.isEmpty ? null : _toggleSelectAllThreads,
            child: Text(_allThreadsSelected ? 'Снять все' : 'Выбрать все'),
          ),
        ],
      ),
      body: _loading
          ? const DeferredPlaceholder(
              child: Center(child: CircularProgressIndicator()),
            )
          : _threads.isEmpty
              ? const Center(child: Text('Нет доступных чатов'))
              : ListView.builder(
                  padding: EdgeInsets.only(bottom: showSend ? 88 : 16),
                  itemCount: _threads.length,
                  itemBuilder: (_, i) {
                    final t = _threads[i];
                    final id = chatAsInt(t['id']);
                    if (id == null) return const SizedBox.shrink();
                    return ChatThreadSelectTile(
                      thread: t,
                      selected: _selected.contains(id),
                      memberByUserId: _memberByUserId,
                      onTap: () => _toggle(id),
                    );
                  },
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
