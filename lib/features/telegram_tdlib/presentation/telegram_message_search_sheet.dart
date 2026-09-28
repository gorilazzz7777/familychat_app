import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:intl/intl.dart';

import '../telegram_tdlib_service.dart';

/// Поиск по сообщениям Telegram-чата через TDLib `searchChatMessages`.
class TelegramMessageSearchSheet extends StatefulWidget {
  const TelegramMessageSearchSheet({
    super.key,
    required this.chatId,
    required this.service,
    required this.onSelect,
  });

  final int chatId;
  final TelegramTdlibService service;
  final ValueChanged<int> onSelect;

  @override
  State<TelegramMessageSearchSheet> createState() =>
      _TelegramMessageSearchSheetState();
}

class _TelegramMessageSearchSheetState
    extends State<TelegramMessageSearchSheet> {
  final _queryController = TextEditingController();
  String _query = '';
  Timer? _debounce;
  bool _searching = false;
  List<TdlibMessage> _results = const [];

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
      final hits = await widget.service.searchChatTextMessages(
        widget.chatId,
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

  String _preview(TdlibMessage m) {
    if (m.isVoiceNote) return 'Голосовое сообщение';
    if (m.isVideoNote) return 'Видеосообщение';
    if (m.isSticker) {
      final e = (m.stickerEmoji ?? '').trim();
      return e.isNotEmpty ? e : 'Стикер';
    }
    if (m.isVideo) return m.isAnimation ? 'GIF' : 'Видео';
    if (m.isDocument) {
      final name = (m.documentFileName ?? '').trim();
      return name.isNotEmpty ? name : 'Файл';
    }
    final t = m.text.trim();
    return t.isNotEmpty ? t : 'Сообщение';
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
                  prefixIcon: const Icon(LucideIcons.search),
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
                          icon: const Icon(LucideIcons.x),
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
                    final sender = m.isOutgoing
                        ? 'Вы'
                        : widget.service.senderDisplayName(m.senderUserId);
                    final created = m.date > 0
                        ? DateTime.fromMillisecondsSinceEpoch(m.date * 1000)
                        : null;
                    return ListTile(
                      title: Text(
                        _preview(m),
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
                      onTap: () => widget.onSelect(m.id),
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
