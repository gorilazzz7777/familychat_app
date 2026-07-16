import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../../core/widgets/family_public_image.dart';
import '../data/calendar_photo_sync_service.dart';

/// Проверка фото из временного альбома перед публикацией в целевой.
class CalendarStagingReviewScreen extends ConsumerStatefulWidget {
  const CalendarStagingReviewScreen({
    super.key,
    required this.info,
  });

  final CalendarPhotoSyncInfo info;

  @override
  ConsumerState<CalendarStagingReviewScreen> createState() =>
      _CalendarStagingReviewScreenState();
}

class _CalendarStagingReviewScreenState
    extends ConsumerState<CalendarStagingReviewScreen> {
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _photos = [];
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  int? _idOf(Map<String, dynamic> photo) {
    final id = photo['id'];
    if (id is int) return id;
    return int.tryParse('$id');
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await ref
          .read(familychatRepositoryProvider)
          .fetchCalendarStagingPhotos(widget.info.eventId);
      final photos =
          (data['photos'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      if (!mounted) return;
      setState(() {
        _photos = photos;
        _selected
          ..clear()
          ..addAll(photos.map(_idOf).whereType<int>());
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _promoteSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(familychatRepositoryProvider).promoteCalendarStagingPhotos(
            widget.info.eventId,
            _selected.toList(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('В альбом добавлено: ${_selected.length}')),
      );
      await _load();
      if (!mounted) return;
      if (_photos.isEmpty) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deletePhoto(int attachmentId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить фото?'),
        content: const Text(
          'Оно больше не будет предлагаться для этого события.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(familychatRepositoryProvider).rejectCalendarStagingPhotos(
            widget.info.eventId,
            [attachmentId],
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FamilyAppBar.build(
        title: 'Проверка фото',
        actions: [
          if (_photos.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        if (_selected.length == _photos.length) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(_photos.map(_idOf).whereType<int>());
                        }
                      });
                    },
              child: Text(
                _selected.length == _photos.length ? 'Снять все' : 'Выбрать все',
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _photos.isEmpty
              ? const Center(child: Text('Нет фото на проверке'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        'Событие «${widget.info.title}». '
                        'Отметьте фото для общего альбома. '
                        'Неотмеченные останутся здесь. '
                        '«Удалить» — больше не предлагать.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: _photos.length,
                        itemBuilder: (context, i) {
                          final photo = _photos[i];
                          final id = _idOf(photo);
                          if (id == null) return const SizedBox.shrink();
                          final url = photo['file_url']?.toString() ?? '';
                          final selected = _selected.contains(id);
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              InkWell(
                                onTap: () {
                                  setState(() {
                                    if (selected) {
                                      _selected.remove(id);
                                    } else {
                                      _selected.add(id);
                                    }
                                  });
                                },
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: selected
                                          ? Theme.of(context).colorScheme.primary
                                          : Colors.transparent,
                                      width: 3,
                                    ),
                                  ),
                                  child: url.isEmpty
                                      ? const ColoredBox(color: Colors.black12)
                                      : FamilyPublicImage(
                                          url: url,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                              ),
                              Positioned(
                                top: 4,
                                left: 4,
                                child: Icon(
                                  selected
                                      ? Icons.check_circle
                                      : Icons.circle_outlined,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.white,
                                  shadows: const [
                                    Shadow(blurRadius: 4, color: Colors.black54),
                                  ],
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.white,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 4,
                                        color: Colors.black54,
                                      ),
                                    ],
                                  ),
                                  onPressed:
                                      _busy ? null : () => _deletePhoto(id),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: FilledButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : _promoteSelected,
                          child: Text(
                            _selected.isEmpty
                                ? 'Выберите фото'
                                : 'В альбом (${_selected.length})',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
