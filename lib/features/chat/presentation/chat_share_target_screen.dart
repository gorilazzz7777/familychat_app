import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_handler/share_handler.dart';

import '../../../core/providers/app_providers.dart';
import '../data/chat_realtime_utils.dart';
import '../data/share_attachment_loader.dart';

/// Выбор чата для отправки контента из системного «Поделиться».
class ChatShareTargetScreen extends ConsumerStatefulWidget {
  const ChatShareTargetScreen({super.key, required this.media});

  final SharedMedia media;

  @override
  ConsumerState<ChatShareTargetScreen> createState() => _ChatShareTargetScreenState();
}

class _ChatShareTargetScreenState extends ConsumerState<ChatShareTargetScreen> {
  List<Map<String, dynamic>> _threads = [];
  final _selected = <int>{};
  bool _loading = true;
  bool _sending = false;
  String? _loadError;
  late final TextEditingController _captionController;
  List<ShareAttachmentData> _attachments = const [];

  @override
  void initState() {
    super.initState();
    _captionController = TextEditingController(text: widget.media.content ?? '');
    _load();
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final attachments = await readShareAttachments(widget.media);
      final list = await ref.read(familychatRepositoryProvider).chatThreads();
      if (!mounted) return;
      setState(() {
        _attachments = attachments;
        _threads = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Не удалось подготовить отправку';
        _loading = false;
      });
    }
  }

  bool get _canSend {
    final caption = _captionController.text.trim();
    return _selected.isNotEmpty && (caption.isNotEmpty || _attachments.isNotEmpty);
  }

  Future<void> _send() async {
    if (!_canSend || _sending) return;
    setState(() => _sending = true);

    final caption = _captionController.text.trim();
    final repo = ref.read(familychatRepositoryProvider);
    final threadIds = _selected.toList();

    try {
      for (final threadId in threadIds) {
        final attachmentIds = <int>[];
        for (final att in _attachments) {
          final uploaded = await repo.uploadChatAttachmentBytes(
            threadId,
            bytes: Uint8List.fromList(att.bytes),
            filename: att.filename,
            contentType: att.contentType,
          );
          final id = chatAsInt(uploaded['id']);
          if (id != null) attachmentIds.add(id);
        }
        await repo.sendThreadMessage(
          threadId,
          body: caption.isEmpty ? null : caption,
          attachmentIds: attachmentIds.isEmpty ? null : attachmentIds,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            threadIds.length == 1 ? 'Отправлено' : 'Отправлено в ${threadIds.length} чата',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = _captionController.text.trim();
    final hasPayload = caption.isNotEmpty || _attachments.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Поделиться в чат'),
        actions: [
          TextButton(
            onPressed: !_canSend || _sending ? null : _send,
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
          : _loadError != null
              ? Center(child: Text(_loadError!))
              : !hasPayload
                  ? const Center(child: Text('Нет данных для отправки'))
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_attachments.isNotEmpty)
                                SizedBox(
                                  height: 88,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _attachments.length,
                                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                                    itemBuilder: (_, i) {
                                      final att = _attachments[i];
                                      if (att.isImage) {
                                        return ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Image.memory(
                                            Uint8List.fromList(att.bytes),
                                            width: 88,
                                            height: 88,
                                            fit: BoxFit.cover,
                                          ),
                                        );
                                      }
                                      return Container(
                                        width: 88,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(8),
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            const Icon(Icons.insert_drive_file_outlined),
                                            const SizedBox(width: 4),
                                            Text(
                                              att.filename,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              textAlign: TextAlign.center,
                                              style: Theme.of(context).textTheme.labelSmall,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              if (_attachments.isNotEmpty) const SizedBox(height: 12),
                              TextField(
                                controller: _captionController,
                                minLines: 1,
                                maxLines: 4,
                                decoration: const InputDecoration(
                                  labelText: 'Подпись',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: _threads.isEmpty
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
                        ),
                      ],
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
