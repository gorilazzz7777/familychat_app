import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Поиск по загруженным сообщениям чата.
class ChatMessageSearchSheet extends StatefulWidget {
  const ChatMessageSearchSheet({
    super.key,
    required this.messages,
    required this.onSelect,
  });

  final List<Map<String, dynamic>> messages;
  final ValueChanged<int> onSelect;

  @override
  State<ChatMessageSearchSheet> createState() => _ChatMessageSearchSheetState();
}

class _ChatMessageSearchSheetState extends State<ChatMessageSearchSheet> {
  final _queryController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return widget.messages.where((m) {
      final body = m['body']?.toString().toLowerCase() ?? '';
      if (body.contains(q)) return true;
      final atts = (m['attachments'] as List?) ?? [];
      for (final a in atts) {
        if (a is! Map) continue;
        final name = a['filename']?.toString().toLowerCase() ?? '';
        if (name.contains(q)) return true;
      }
      return false;
    }).toList().reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('dd.MM.yyyy HH:mm');
    final results = _results;

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
                            _queryController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.clear),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_query.trim().isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Введите текст для поиска'),
              )
            else if (results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ничего не найдено'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: results.length,
                  itemBuilder: (_, i) {
                    final m = results[i];
                    final id = m['id'] as int;
                    final body = m['body']?.toString() ?? '';
                    final sender = m['sender_name']?.toString() ?? '';
                    final created = DateTime.tryParse(m['created_at']?.toString() ?? '');
                    final preview = body.isNotEmpty
                        ? body
                        : _attachmentPreview(m);
                    return ListTile(
                      title: Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (sender.isNotEmpty) sender,
                          if (created != null) timeFmt.format(created.toLocal()),
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

  String _attachmentPreview(Map<String, dynamic> m) {
    final atts = (m['attachments'] as List?) ?? [];
    if (atts.isEmpty) return 'Сообщение';
    final first = atts.first;
    if (first is! Map) return 'Вложение';
    if (first['kind'] == 'image') return 'Фото';
    return first['filename']?.toString() ?? 'Файл';
  }
}
