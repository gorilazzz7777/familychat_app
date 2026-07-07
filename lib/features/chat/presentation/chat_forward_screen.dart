import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../data/chat_realtime_utils.dart';

/// Выбор чатов для пересылки сообщений.
class ChatForwardScreen extends ConsumerStatefulWidget {
  const ChatForwardScreen({
    super.key,
    required this.sourceThreadId,
    required this.messageIds,
  });

  final int sourceThreadId;
  final List<int> messageIds;

  @override
  ConsumerState<ChatForwardScreen> createState() => _ChatForwardScreenState();
}

class _ChatForwardScreenState extends ConsumerState<ChatForwardScreen> {
  List<Map<String, dynamic>> _threads = [];
  final _selected = <int>{};
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(familychatRepositoryProvider).chatThreads();
      if (!mounted) return;
      setState(() {
        _threads = list.where((t) => t['id'] != widget.sourceThreadId).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
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

  List<int> get _selectableThreadIds => _threads.map(chatAsInt).whereType<int>().toList();

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Переслать'),
        actions: [
          TextButton(
            onPressed: _selectableThreadIds.isEmpty ? null : _toggleSelectAllThreads,
            child: Text(_allThreadsSelected ? 'Снять все' : 'Выбрать все'),
          ),
          TextButton(
            onPressed: _selected.isEmpty || _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('Отправить (${_selected.length})'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _threads.isEmpty
              ? const Center(child: Text('Нет доступных чатов'))
              : ListView.builder(
                  itemCount: _threads.length,
                  itemBuilder: (_, i) {
                    final t = _threads[i];
                    final id = chatAsInt(t['id']);
                    if (id == null) return const SizedBox.shrink();
                    final selected = _selected.contains(id);
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.add(id);
                          } else {
                            _selected.remove(id);
                          }
                        });
                      },
                      title: Text(t['title']?.toString() ?? 'Чат'),
                      subtitle: Text(_preview(t)),
                    );
                  },
                ),
    );
  }

  String _preview(Map<String, dynamic> thread) {
    final last = thread['last_message'] as Map<String, dynamic>?;
    if (last == null) return 'Нет сообщений';
    final body = last['body']?.toString() ?? '';
    if (body.isNotEmpty) return body;
    return 'Вложение';
  }
}
