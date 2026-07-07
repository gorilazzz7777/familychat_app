import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../chat/presentation/widgets/chat_network_image.dart';

/// Выбор фото из галереи для добавления в пользовательский альбом.
class PickGalleryPhotosSheet extends ConsumerStatefulWidget {
  const PickGalleryPhotosSheet({
    super.key,
    required this.userId,
    this.excludeAttachmentIds = const {},
  });

  final int userId;
  final Set<int> excludeAttachmentIds;

  static Future<List<int>?> show(
    BuildContext context, {
    required int userId,
    Set<int> excludeAttachmentIds = const {},
  }) {
    return showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => ProviderScope(
        parent: ProviderScope.containerOf(context),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (_, scrollController) => PickGalleryPhotosSheet(
            userId: userId,
            excludeAttachmentIds: excludeAttachmentIds,
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<PickGalleryPhotosSheet> createState() => _PickGalleryPhotosSheetState();
}

class _PickGalleryPhotosSheetState extends ConsumerState<PickGalleryPhotosSheet> {
  final List<Map<String, dynamic>> _photos = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _offset = 0;
  int _total = 0;
  static const _pageSize = 60;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _offset = 0;
        _photos.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final data = await ref.read(familychatRepositoryProvider).memberGalleryPickablePhotos(
            widget.userId,
            offset: _offset,
            limit: _pageSize,
          );
      if (!mounted) return;
      final batch = (data['photos'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _total = data['total'] is int ? data['total'] as int : int.tryParse('${data['total']}') ?? 0;
        _photos.addAll(batch);
        _offset += batch.length;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  int? _photoId(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Выберите фото',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, _selected.toList()),
                child: Text('Готово (${_selected.length})'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error!))
                  : _photos.isEmpty
                      ? const Center(child: Text('Нет доступных фото'))
                      : NotificationListener<ScrollNotification>(
                          onNotification: (n) {
                            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200 &&
                                !_loadingMore &&
                                _photos.length < _total) {
                              _load(reset: false);
                            }
                            return false;
                          },
                          child: GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            itemCount: _photos.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (_, i) {
                              if (i >= _photos.length) {
                                return const Center(
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                );
                              }
                              final photo = _photos[i];
                              final photoId = _photoId(photo);
                              final threadId = photo['thread_id'];
                              if (photoId == null || threadId is! int) {
                                return const ColoredBox(color: Color(0x22000000));
                              }
                              if (widget.excludeAttachmentIds.contains(photoId)) {
                                return const ColoredBox(
                                  color: Color(0x33000000),
                                  child: Center(
                                    child: Icon(Icons.check, color: Colors.white70),
                                  ),
                                );
                              }
                              final selected = _selected.contains(photoId);
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    if (selected) {
                                      _selected.remove(photoId);
                                    } else {
                                      _selected.add(photoId);
                                    }
                                  });
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ChatNetworkImage(
                                      threadId: threadId,
                                      attachment: photo,
                                      fit: BoxFit.cover,
                                    ),
                                    if (selected)
                                      Container(
                                        color: Colors.black38,
                                        child: const Icon(
                                          Icons.check_circle,
                                          color: Colors.white,
                                          size: 32,
                                        ),
                                      ),
                                  ],
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
