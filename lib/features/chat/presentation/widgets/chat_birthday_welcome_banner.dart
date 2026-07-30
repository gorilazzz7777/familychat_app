import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../familychat/data/familychat_repository.dart';
import '../record_video_circle_screen.dart';
import 'chat_attach_sheet/chat_attach_sheet.dart';

/// Системное приветствие в чате подготовки к дню рождения с отложенным поздравлением.
class ChatBirthdayWelcomeBanner extends StatelessWidget {
  const ChatBirthdayWelcomeBanner({
    super.key,
    required this.body,
    this.createdAt,
    this.scheduled,
    this.onCompose,
    this.saving = false,
  });

  final String body;
  final DateTime? createdAt;
  final Map<String, dynamic>? scheduled;
  final VoidCallback? onCompose;
  final bool saving;

  int get _pendingCount {
    final raw = scheduled?['pending_count'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  bool get _hasMine {
    final mine = scheduled?['mine'];
    if (mine is! Map) return false;
    if ((mine['body']?.toString().trim().isNotEmpty) ?? false) return true;
    final atts = mine['attachments'] ?? mine['attachment_ids'];
    return atts is List && atts.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final timeFmt = DateFormat.Hm();
    final canWrite = scheduled?['can_write'] == true && onCompose != null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.92,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.tertiaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cs.tertiary.withValues(alpha: 0.35)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.cake_rounded, color: cs.tertiary, size: 20),
                      const SizedBox(width: 6),
                      Text(
                        'Подготовка к дню рождения',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: cs.onTertiaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onTertiaryContainer,
                      height: 1.35,
                    ),
                  ),
                  if (_pendingCount > 0) ...[
                    const SizedBox(height: 10),
                    Text(
                      _pendingCount == 1
                          ? '1 поздравление готово'
                          : '$_pendingCount поздравления готовы',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: cs.tertiary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (canWrite) ...[
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      onPressed: saving ? null : onCompose,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_hasMine ? Icons.edit_outlined : Icons.card_giftcard_outlined),
                          label: Text(
                        _hasMine
                            ? 'Изменить поздравление'
                            : 'Подготовить поздравление',
                      ),
                    ),
                    if (_hasMine) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Отправится автоматически, когда именинник подключится',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onTertiaryContainer.withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ],
                  if (createdAt != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      timeFmt.format(createdAt!.toLocal()),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onTertiaryContainer.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showBirthdayScheduledCongratulationDialog({
  required BuildContext context,
  required int threadId,
  required String initialText,
  required List<Map<String, dynamic>> initialAttachments,
  int? initialVideoNoteDurationMs,
  required FamilyChatRepository repository,
  required Future<void> Function({
    required String body,
    required List<int> attachmentIds,
    int? videoNoteDurationMs,
  }) onSave,
  Future<void> Function()? onDelete,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _BirthdayScheduledCongratulationDialog(
      threadId: threadId,
      initialText: initialText,
      initialAttachments: initialAttachments,
      initialVideoNoteDurationMs: initialVideoNoteDurationMs,
      repository: repository,
      onSave: onSave,
      onDelete: onDelete,
    ),
  );
}

class _PendingAttachment {
  _PendingAttachment({
    required this.id,
    required this.kind,
    required this.filename,
    this.fileUrl,
    this.localBytes,
    this.isVideoNote = false,
  });

  final int id;
  final String kind;
  final String filename;
  final String? fileUrl;
  final Uint8List? localBytes;
  final bool isVideoNote;
}

class _BirthdayScheduledCongratulationDialog extends StatefulWidget {
  const _BirthdayScheduledCongratulationDialog({
    required this.threadId,
    required this.initialText,
    required this.initialAttachments,
    required this.repository,
    required this.onSave,
    this.initialVideoNoteDurationMs,
    this.onDelete,
  });

  final int threadId;
  final String initialText;
  final List<Map<String, dynamic>> initialAttachments;
  final int? initialVideoNoteDurationMs;
  final FamilyChatRepository repository;
  final Future<void> Function({
    required String body,
    required List<int> attachmentIds,
    int? videoNoteDurationMs,
  }) onSave;
  final Future<void> Function()? onDelete;

  @override
  State<_BirthdayScheduledCongratulationDialog> createState() =>
      _BirthdayScheduledCongratulationDialogState();
}

class _BirthdayScheduledCongratulationDialogState
    extends State<_BirthdayScheduledCongratulationDialog> {
  static const _maxAttachments = 10;

  late final TextEditingController _controller;
  final _formKey = GlobalKey<FormState>();
  final List<_PendingAttachment> _attachments = [];
  int? _videoNoteDurationMs;
  bool _saving = false;
  bool _uploading = false;

  static final _compactTextButton = TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  static final _compactFilledButton = FilledButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );

  bool get _hadInitialContent =>
      widget.initialText.trim().isNotEmpty ||
      widget.initialAttachments.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _videoNoteDurationMs = widget.initialVideoNoteDurationMs;
    for (final raw in widget.initialAttachments) {
      final id = raw['id'];
      final aid = id is int ? id : int.tryParse('$id');
      if (aid == null || aid <= 0) continue;
      final kind = raw['kind']?.toString() ?? 'file';
      _attachments.add(
        _PendingAttachment(
          id: aid,
          kind: kind,
          filename: raw['filename']?.toString() ?? 'Файл',
          fileUrl: raw['file_url']?.toString(),
          isVideoNote: kind == 'video' && _videoNoteDurationMs != null,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickMedia() async {
    if (_saving || _uploading) return;
    await ChatAttachSheet.show(
      context,
      style: ChatAttachSheetStyle.phoneMedia,
      onSendMedia: (caption, items) async {
        if (items.isEmpty) return;
        final room = _maxAttachments - _attachments.length;
        if (room <= 0) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не более $_maxAttachments вложений')),
          );
          return;
        }
        final batch = items.take(room).toList();
        setState(() => _uploading = true);
        try {
          for (final item in batch) {
            final uploaded = await widget.repository.uploadChatAttachmentBytes(
              widget.threadId,
              bytes: item.bytes,
              filename: item.filename,
              contentType: item.contentType,
            );
            final id = uploaded['id'];
            final aid = id is int ? id : int.tryParse('$id');
            if (aid == null) continue;
            if (!mounted) return;
            setState(() {
              _attachments.add(
                _PendingAttachment(
                  id: aid,
                  kind: uploaded['kind']?.toString() ??
                      (item.kind == 'video' ? 'video' : 'image'),
                  filename: uploaded['filename']?.toString() ?? item.filename,
                  fileUrl: uploaded['file_url']?.toString(),
                  localBytes: item.bytes,
                ),
              );
              if (caption.trim().isNotEmpty && _controller.text.trim().isEmpty) {
                _controller.text = caption.trim();
              }
            });
          }
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Не удалось загрузить: $e')),
          );
        } finally {
          if (mounted) setState(() => _uploading = false);
        }
      },
      onRecordVideoCircle: () => unawaited(_recordCircle()),
    );
  }

  Future<void> _recordCircle() async {
    if (_saving || _uploading) return;
    if (_attachments.length >= _maxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не более $_maxAttachments вложений')),
      );
      return;
    }
    final result = await RecordVideoCircleScreen.open(context);
    if (result == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final uploaded = await widget.repository.uploadChatAttachmentBytes(
        widget.threadId,
        bytes: result.bytes,
        filename: result.filename,
        contentType: result.contentType,
      );
      final id = uploaded['id'];
      final aid = id is int ? id : int.tryParse('$id');
      if (aid == null) throw Exception('Нет id вложения');
      if (!mounted) return;
      setState(() {
        _attachments.add(
          _PendingAttachment(
            id: aid,
            kind: 'video',
            filename: result.filename,
            fileUrl: uploaded['file_url']?.toString(),
            localBytes: result.bytes,
            isVideoNote: true,
          ),
        );
        _videoNoteDurationMs = result.durationMs;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить кружок: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removeAttachment(int id) {
    setState(() {
      _attachments.removeWhere((a) => a.id == id);
      if (!_attachments.any((a) => a.isVideoNote)) {
        _videoNoteDurationMs = null;
      }
    });
  }

  Future<void> _submit({required bool delete}) async {
    if (_saving || _uploading) return;
    if (delete) {
      final onDelete = widget.onDelete;
      if (onDelete == null) return;
      setState(() => _saving = true);
      try {
        await onDelete();
        if (!mounted) return;
        Navigator.of(context).pop();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить: $e')),
        );
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) {
      _formKey.currentState?.validate();
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false) && text.isNotEmpty) {
      return;
    }
    if (text.isEmpty && _attachments.isEmpty) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        body: text,
        attachmentIds: _attachments.map((a) => a.id).toList(),
        videoNoteDurationMs: _videoNoteDurationMs,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сохранить: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _uploading;
    return AlertDialog(
      scrollable: true,
      title: const Text('Поздравление имениннику'),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText: 'Напишите тёплые слова…',
                alignLabelWithHint: true,
              ),
              validator: (value) {
                if ((value ?? '').trim().isEmpty && _attachments.isEmpty) {
                  return 'Добавьте текст или вложение';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            if (_attachments.isNotEmpty)
              SizedBox(
                height: 72,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _attachments.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final att = _attachments[index];
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 72,
                            height: 72,
                            child: att.localBytes != null &&
                                    (att.kind == 'image' || att.isVideoNote)
                                ? Image.memory(
                                    att.localBytes!,
                                    fit: BoxFit.cover,
                                  )
                                : ColoredBox(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    child: Icon(
                                      att.kind == 'video' || att.isVideoNote
                                          ? Icons.videocam_outlined
                                          : att.kind == 'image'
                                              ? Icons.image_outlined
                                              : Icons.insert_drive_file_outlined,
                                    ),
                                  ),
                          ),
                        ),
                        Positioned(
                          top: -6,
                          right: -6,
                          child: IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            style: IconButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(28, 28),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: busy ? null : () => _removeAttachment(att.id),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            if (_attachments.isNotEmpty) const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _pickMedia,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Медиа'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : () => unawaited(_recordCircle()),
                    icon: const Icon(Icons.radio_button_checked),
                    label: const Text('Кружок'),
                  ),
                ),
              ],
            ),
            if (_uploading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onDelete != null && _hadInitialContent)
                  TextButton(
                    style: _compactTextButton,
                    onPressed: busy ? null : () => _submit(delete: true),
                    child: const Text('Удалить'),
                  ),
                TextButton(
                  style: _compactTextButton,
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  style: _compactFilledButton,
                  onPressed: busy ? null : () => _submit(delete: false),
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
