import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../profile/presentation/album_upload_file_bytes.dart';
import '../../../../../core/media/gallery_media_utils.dart';
import '../../../data/chat_attach_local_cache.dart';
import '../../../data/chat_recent_files.dart';
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
  List<ChatRecentFileEntry> _recent = [];
  bool _loadingRecent = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final list = await ChatRecentFilesStore.load();
    if (!mounted) return;
    setState(() {
      _recent = list;
      _loadingRecent = false;
    });
  }

  Future<void> _pickStorage() async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: !kIsWeb,
      withReadStream: kIsWeb,
      readSequential: kIsWeb,
    );
    if (picked == null || picked.files.isEmpty) return;
    final next = [...widget.selected];
    for (final f in picked.files) {
      final bytes = await readAlbumUploadFileBytes(f);
      if (bytes == null || bytes.isEmpty) continue;
      final ct = contentTypeForFilename(f.name);
      final kind = ct.startsWith('image/')
          ? 'image'
          : (ct.startsWith('video/') ? 'video' : 'file');
      next.add(
        ChatAttachSelectionItem(
          id: 'file_${f.name}_${bytes.length}_${DateTime.now().microsecondsSinceEpoch}',
          filename: f.name,
          bytes: bytes,
          contentType: ct,
          localPath: f.path,
          kind: kind,
        ),
      );
      if (!kIsWeb && kind == 'file') {
        await ChatRecentFilesStore.remember(
          ChatRecentFileEntry(
            filename: f.name,
            sizeBytes: bytes.length,
            path: f.path,
            contentType: ct,
          ),
        );
      }
    }
    widget.onSelectedChanged(next);
    await _loadRecent();
  }

  Future<void> _addRecent(ChatRecentFileEntry entry) async {
    if (kIsWeb || entry.path == null || entry.path!.isEmpty) return;
    try {
      final bytes = await ChatAttachLocalCache.readBytes(entry.path);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Файл больше недоступен')),
          );
        }
        return;
      }
      final item = ChatAttachSelectionItem(
        id: 'recent_${entry.path}_${DateTime.now().microsecondsSinceEpoch}',
        filename: entry.filename,
        bytes: bytes,
        contentType: entry.contentType ?? contentTypeForFilename(entry.filename),
        localPath: entry.path,
        kind: 'file',
      );
      widget.onSelectedChanged([...widget.selected, item]);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть файл')),
        );
      }
    }
  }

  String _sizeLabel(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} КБ';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      children: [
        ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.green.shade600,
            child: const Icon(Icons.storage, color: Colors.white),
          ),
          title: const Text('Внутреннее хранилище'),
          subtitle: const Text('Поиск в файловой системе'),
          onTap: _pickStorage,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Недавние файлы',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (_loadingRecent)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_recent.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              kIsWeb
                  ? 'Недавние файлы недоступны в браузере'
                  : 'Пока нет недавних файлов',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ..._recent.map(
            (e) => ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.insert_drive_file_outlined),
                  ),
                ),
              ),
              title: Text(e.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_sizeLabel(e.sizeBytes)),
              onTap: () => _addRecent(e),
            ),
          ),
      ],
    );
  }
}
