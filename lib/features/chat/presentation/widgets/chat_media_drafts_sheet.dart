import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/media/video_upload_pipeline.dart';
import '../../../../core/widgets/family_compose_input.dart';

/// Подпись + список фото/видео перед отправкой (с ошибками размера).
class ChatMediaDraftsSheet extends StatefulWidget {
  const ChatMediaDraftsSheet({
    super.key,
    required this.drafts,
    required this.onSend,
    this.preparing = false,
    this.prepareLabel,
    this.prepareProgress,
  });

  final List<MediaUploadDraft> drafts;
  final Future<void> Function(String caption, List<MediaUploadDraft> drafts)
      onSend;
  final bool preparing;
  final String? prepareLabel;
  final double? prepareProgress;

  static Future<void> show(
    BuildContext context, {
    required List<MediaUploadDraft> drafts,
    required Future<void> Function(String caption, List<MediaUploadDraft> drafts)
        onSend,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.black,
      isDismissible: true,
      builder: (_) => ChatMediaDraftsSheet(
        drafts: drafts,
        onSend: onSend,
      ),
    );
  }

  @override
  State<ChatMediaDraftsSheet> createState() => _ChatMediaDraftsSheetState();
}

class _ChatMediaDraftsSheetState extends State<ChatMediaDraftsSheet> {
  final _captionController = TextEditingController();
  late List<MediaUploadDraft> _drafts;
  bool _sending = false;
  double _uploadProgress = 0;
  String _uploadLabel = '';

  @override
  void initState() {
    super.initState();
    _drafts = List.of(widget.drafts);
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    final valid = _drafts.where((d) => d.canUpload).toList();
    // Невалидные просто не грузим — даже если остались в списке.
    setState(() {
      _sending = true;
      _uploadProgress = 0;
      _uploadLabel = 'Отправка…';
    });
    try {
      await widget.onSend(_captionController.text.trim(), valid);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отправки: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.92,
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: _sending ? null : () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
          if (_sending || widget.preparing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.preparing
                        ? (widget.prepareLabel ?? 'Подготовка…')
                        : _uploadLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: widget.preparing
                        ? widget.prepareProgress
                        : (_uploadProgress <= 0 ? null : _uploadProgress),
                    backgroundColor: Colors.white12,
                    color: Colors.lightBlueAccent,
                  ),
                ],
              ),
            ),
          Expanded(
            child: _drafts.isEmpty
                ? const Center(
                    child: Text(
                      'Нет медиа',
                      style: TextStyle(color: Colors.white54),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.78,
                    ),
                    itemCount: _drafts.length,
                    itemBuilder: (context, i) {
                      final d = _drafts[i];
                      return _DraftTile(
                        draft: d,
                        onRemove: _sending
                            ? null
                            : () => setState(() => _drafts.removeAt(i)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12 + bottomInset),
            child: FamilyComposeInput(
              controller: _captionController,
              hintText: 'Подпись...',
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSend: _sending ? () {} : _submit,
              fillColor: Colors.white.withValues(alpha: 0.12),
              borderColor: Colors.white.withValues(alpha: 0.2),
              textColor: Colors.white,
              hintColor: Colors.white.withValues(alpha: 0.6),
              sendIconColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({required this.draft, this.onRemove});

  final MediaUploadDraft draft;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final error = draft.tooLarge;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: error ? Colors.redAccent : Colors.white24,
          width: error ? 2 : 1,
        ),
        color: Colors.white10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(11)),
                  child: _preview(draft),
                ),
                if (draft.isVideo)
                  const Align(
                    alignment: Alignment.center,
                    child: Icon(Icons.play_circle_outline,
                        color: Colors.white70, size: 40),
                  ),
                if (onRemove != null)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onRemove,
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (error)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Text(
                draft.errorMessage ??
                    'Видео слишком большое и не будет загружено',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 11,
                  height: 1.25,
                ),
              ),
            )
          else
            const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _preview(MediaUploadDraft draft) {
    final bytes = draft.thumbnailBytes ??
        (draft.isImage ? draft.originalBytes : null);
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }
    return ColoredBox(
      color: Colors.black26,
      child: Icon(
        draft.previewBroken || draft.isVideo
            ? Icons.broken_image_outlined
            : Icons.image_not_supported_outlined,
        color: Colors.white38,
        size: 40,
      ),
    );
  }
}

/// Полноэкранный лоадер подготовки/загрузки с полоской прогресса.
Future<T?> showMediaProgressDialog<T>({
  required BuildContext context,
  required String title,
  required Future<T> Function(void Function(double p, String label) report)
      work,
}) async {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return _MediaProgressDialog(title: title, work: work);
    },
  );
}

class _MediaProgressDialog extends StatefulWidget {
  const _MediaProgressDialog({required this.title, required this.work});

  final String title;
  final Future<dynamic> Function(
      void Function(double p, String label) report) work;

  @override
  State<_MediaProgressDialog> createState() => _MediaProgressDialogState();
}

class _MediaProgressDialogState extends State<_MediaProgressDialog> {
  double _progress = 0;
  String _label = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final result = await widget.work((p, label) {
          if (!mounted) return;
          setState(() {
            _progress = p.clamp(0.0, 1.0);
            _label = label;
          });
        });
        if (mounted) Navigator.of(context).pop(result);
      } catch (e) {
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка подготовки: $e')),
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_label.isEmpty ? '…' : _label),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _progress <= 0 ? null : _progress,
          ),
        ],
      ),
    );
  }
}

/// Удобная обёртка: байты изображения как MediaUploadDraft.
MediaUploadDraft imageDraftFromBytes({
  required Uint8List bytes,
  required String filename,
  String? contentType,
}) {
  return MediaUploadDraft(
    id: 'i_${DateTime.now().microsecondsSinceEpoch}',
    kind: MediaDraftKind.image,
    filename: filename,
    contentType: contentType ?? 'image/jpeg',
    originalBytes: bytes,
    preparedBytes: bytes,
    thumbnailBytes: bytes,
  );
}
