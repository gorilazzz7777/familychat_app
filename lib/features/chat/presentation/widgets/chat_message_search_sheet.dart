import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/local_db/chat_local_store.dart';
import '../../data/chat_message_preview.dart';

/// Поиск по локальной SQLite-истории чата.
class ChatMessageSearchSheet extends StatefulWidget {
  const ChatMessageSearchSheet({
    super.key,
    required this.threadId,
    required this.onSelect,
  });

  final int threadId;
  final ValueChanged<int> onSelect;

  @override
  State<ChatMessageSearchSheet> createState() => _ChatMessageSearchSheetState();
}

class _ChatMessageSearchSheetState extends State<ChatMessageSearchSheet> {
  final _queryController = TextEditingController();
  String _query = '';
  Timer? _debounce;
  bool _searching = false;
  List<Map<String, dynamic>> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _searching = false;
        _results = const [];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_runSearch(trimmed));
    });
  }

  Future<void> _runSearch(String query) async {
    setState(() => _searching = true);
    try {
      final hits = await ChatLocalStore.instance.searchMessages(
        widget.threadId,
        query,
      );
      if (!mounted || _query.trim() != query) return;
      setState(() {
        _results = hits;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || _query.trim() != query) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('dd.MM.yyyy HH:mm');
    final trimmed = _query.trim();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _queryController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Поиск по сообщениям',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          onPressed: () {
                            _debounce?.cancel();
                            _queryController.clear();
                            setState(() {
                              _query = '';
                              _searching = false;
                              _results = const [];
                            });
                          },
                          icon: const Icon(Icons.clear),
                        )
                      : null,
                ),
                onChanged: _onQueryChanged,
              ),
            ),
            if (trimmed.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Введите текст для поиска'),
              )
            else if (_searching)
              const Padding(
                padding: EdgeInsets.all(24),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ничего не найдено'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (_, i) {
                    final m = _results[i];
                    final id = m['id'] as int;
                    final sender = m['sender_name']?.toString() ?? '';
                    final created =
                        DateTime.tryParse(m['created_at']?.toString() ?? '');
                    final preview = chatMessagePreviewText(m);
                    return ListTile(
                      title: Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (sender.isNotEmpty) sender,
                          if (created != null)
                            timeFmt.format(created.toLocal()),
                        ].join(' · '),
                      ),
                      onTap: () => widget.onSelect(id),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
