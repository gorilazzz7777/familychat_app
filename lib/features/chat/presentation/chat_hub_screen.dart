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
  ConsumerState<ChatHubScreen> createState() => _ChatHubScreenState();
}

class _ChatHubScreenState extends ConsumerState<ChatHubScreen> {
  _ChatFilter _filter = _ChatFilter.all;
  List<Map<String, dynamic>> _threads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    FamilyChatRealtime.instance.addListener(_onRealtime);
    _load();
  }

  @override
  void dispose() {
    FamilyChatRealtime.instance.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime(Map<String, dynamic> event) {
    if (event['event'] != 'chat_message') return;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ref.read(familychatRepositoryProvider).chatThreads();
      if (!mounted) return;
      setState(() {
        _threads = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    return _threads.where((t) {
      final kind = t['kind']?.toString() ?? '';
      return switch (_filter) {
        _ChatFilter.all => true,
        _ChatFilter.family => kind == 'family',
        _ChatFilter.dm => kind == 'dm',
        _ChatFilter.group => kind == 'group',
      };
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
          kind: thread['kind']?.toString() ?? 'family',
          peerUserId: thread['peer_user_id'] as int?,
        ),
      ),
    );
    await _load();
  }

  Future<void> _createGroup() async {
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
                          children: const [
                            SizedBox(height: 120),
                            Center(child: Text('Нет чатов')),
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
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: _createGroup,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Создать группу'),
            ),
          ),
        ),
      ],
    );
  }
}
