import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../data/ai_assistant_api.dart';
import 'ai_assistant_conversation_screen.dart';

class AiAssistantSessionList extends ConsumerStatefulWidget {
  const AiAssistantSessionList({super.key});

  @override
  ConsumerState<AiAssistantSessionList> createState() =>
      _AiAssistantSessionListState();
}

class _AiAssistantSessionListState
    extends ConsumerState<AiAssistantSessionList> {
  late final AiAssistantApi _api;
  List<Map<String, dynamic>> _sessions = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final client = ref.read(apiClientProvider);
    _api = AiAssistantApi(client);
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _sessions = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _newChat() async {
    try {
      final session = await _api.createSession();
      final id = session['id'];
      if (id is! int || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AiAssistantConversationScreen(sessionId: id),
        ),
      );
      if (mounted) await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось создать чат: $e')),
      );
    }
  }

  Future<void> _open(Map<String, dynamic> session) async {
    final id = session['id'];
    if (id is! int) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AiAssistantConversationScreen(sessionId: id),
      ),
    );
    if (mounted) await _reload();
  }

  Future<void> _rename(Map<String, dynamic> session) async {
    final id = session['id'];
    if (id is! int) return;
    final controller = TextEditingController(
      text: session['title']?.toString() ?? '',
    );
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Название чата'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty) return;
    try {
      await _api.renameSession(id, next);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> session) async {
    final id = session['id'];
    if (id is! int) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: Text(session['title']?.toString() ?? 'Чат'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.deleteSession(id);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: FilledButton.icon(
            onPressed: _newChat,
            icon: const Icon(Icons.add),
            label: const Text('Новый чат'),
          ),
        ),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _reload, child: const Text('Повторить')),
                ],
              ),
            ),
          )
        else if (_sessions.isEmpty)
          Expanded(
            child: Center(
              child: Text(
                'Пока нет чатов.\nНажмите «Новый чат».',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView.separated(
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final s = _sessions[i];
                  final title = (s['title']?.toString().trim().isNotEmpty == true)
                      ? s['title'].toString()
                      : 'Новый чат';
                  final preview = s['preview']?.toString() ?? '';
                  final capped = s['input_disabled'] == true;
                  return Dismissible(
                    key: ValueKey('ai-session-${s['id']}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: theme.colorScheme.error,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: Icon(Icons.delete, color: theme.colorScheme.onError),
                    ),
                    confirmDismiss: (_) async {
                      await _delete(s);
                      return false;
                    },
                    child: ListTile(
                      title: Text(title),
                      subtitle: Text(
                        capped
                            ? 'Лимит достигнут · начните новый чат'
                            : (preview.isEmpty ? 'Нет сообщений' : preview),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _rename(s),
                      ),
                      onTap: () => _open(s),
                      onLongPress: () => _rename(s),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
