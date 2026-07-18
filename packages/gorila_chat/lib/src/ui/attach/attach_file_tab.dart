import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'attach_media_utils.dart';
import 'chat_attach_models.dart';

class AttachFileTab extends StatefulWidget {
  const AttachFileTab({
    super.key,
    required this.selected,
    required this.onSelectedChanged,
    required this.scrollController,
  });

  final List<ChatAttachSelectionItem> selected;
  final void Function(List<ChatAttachSelectionItem> items) onSelectedChanged;
  final ScrollController scrollController;

  @override
  State<AttachFileTab> createState() => _AttachFileTabState();
}

class _AttachFileTabState extends State<AttachFileTab> {
  bool _picking = false;

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final next = List<ChatAttachSelectionItem>.from(widget.selected);
      for (final file in picked.files) {
        Uint8List? bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        next.add(
          ChatAttachSelectionItem(
            id: 'file-${file.name}-${bytes.length}-${next.length}',
            filename: file.name,
            bytes: bytes,
            kind: 'file',
            contentType: contentTypeForFilename(file.name),
          ),
        );
      }
      widget.onSelectedChanged(next);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(Icons.folder_open_outlined, color: scheme.primary),
          ),
          title: const Text('Выбрать файл'),
          subtitle: Text(
            kIsWeb
                ? 'Документы и медиа с устройства'
                : 'Документы, фото и видео',
          ),
          trailing: _picking
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: _picking ? null : _pick,
        ),
        if (widget.selected.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Выбрано: ${widget.selected.length}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ],
      ],
    );
  }
}
