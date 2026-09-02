import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../gallery/presentation/gallery_media_thumbnail.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../profile/presentation/photo_slideshow_screen.dart';
import 'child_milestone_detail_screen.dart';

/// Просмотр заполненной вехи (только чтение), как в Dairy.
class ChildMilestoneViewScreen extends ConsumerStatefulWidget {
  const ChildMilestoneViewScreen({
    super.key,
    required this.code,
    this.initialTitle,
    this.canEdit = false,
    this.childId,
    this.childName,
  });

  final String code;
  final String? initialTitle;
  final bool canEdit;
  final int? childId;
  final String? childName;

  @override
  ConsumerState<ChildMilestoneViewScreen> createState() =>
      _ChildMilestoneViewScreenState();
}

class _ChildMilestoneViewScreenState
    extends ConsumerState<ChildMilestoneViewScreen> {
  Map<String, dynamic>? _milestone;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _milestone == null;
      _error = null;
    });
    try {
      final m = await ref
          .read(familychatRepositoryProvider)
          .diaryMilestoneDetail(widget.code);
      if (!mounted) return;
      final photos = _photosOf(m);
      MediaLocalIndex.hydrateAttachments(photos);
      unawaited(MediaIncomingSync.ensureGalleryPhotos(photos));
      setState(() {
        _milestone = m;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_milestone == null) {
          _error = 'Не удалось загрузить веху';
        }
      });
    }
  }

  String get _title {
    final fromMilestone = _milestone?['title']?.toString().trim();
    if (fromMilestone != null && fromMilestone.isNotEmpty) return fromMilestone;
    final initial = widget.initialTitle?.trim();
    if (initial != null && initial.isNotEmpty) return initial;
    return 'Веха';
  }

  List<Map<String, dynamic>> _photosOf(Map<String, dynamic>? m) {
    final raw = m?['photos'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  List<Map<String, dynamic>> get _photos => _photosOf(_milestone);

  List<Map<String, dynamic>> get _galleryPhotos {
    final out = <Map<String, dynamic>>[];
    for (final photo in _photos) {
      final id = photo['attachment_id'] ?? photo['id'];
      final aid = id is int ? id : int.tryParse('$id');
      final url = (photo['file_url'] ?? photo['url'] ?? '').toString();
      if (aid == null && url.isEmpty) continue;
      out.add({
        ...photo,
        if (aid != null) 'id': aid,
        if (url.isNotEmpty) 'file_url': url,
      });
    }
    return out;
  }

  List<_MilestoneFieldRow> get _filledFields {
    final m = _milestone;
    if (m == null) return const [];
    final rows = <_MilestoneFieldRow>[];

    final achievedRaw = m['achieved_at']?.toString();
    final achievedAt = achievedRaw != null && achievedRaw.isNotEmpty
        ? DateTime.tryParse(achievedRaw)
        : null;
    if (achievedAt != null) {
      rows.add(
        _MilestoneFieldRow(
          label: 'Когда',
          value: DateFormat('d MMMM yyyy', 'ru').format(achievedAt),
          icon: Icons.event_outlined,
        ),
      );
    }

    final note = m['note']?.toString().trim() ?? '';
    if (note.isNotEmpty) {
      rows.add(
        _MilestoneFieldRow(
          label: 'Комментарий',
          value: note,
          icon: Icons.notes_outlined,
        ),
      );
    }

    final weight = _formatNumber(m['weight_kg']);
    if (weight != null) {
      rows.add(
        _MilestoneFieldRow(
          label: 'Вес',
          value: '$weight кг',
          icon: Icons.monitor_weight_outlined,
        ),
      );
    }

    final height = _formatNumber(m['height_cm']);
    if (height != null) {
      rows.add(
        _MilestoneFieldRow(
          label: 'Рост',
          value: '$height см',
          icon: Icons.height_outlined,
        ),
      );
    }

    return rows;
  }

  String? _formatNumber(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) {
      final d = raw.toDouble();
      if (d == d.roundToDouble()) return '${d.toInt()}';
      return '$d';
    }
    final text = '$raw'.trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _openPhoto(int index) async {
    final galleryPhotos = _galleryPhotos;
    if (galleryPhotos.isEmpty) return;
    int? currentUserId;
    try {
      final status = await ref.read(familychatRepositoryProvider).status();
      final uid = status['user_id'];
      currentUserId = uid is int ? uid : int.tryParse('$uid');
    } catch (_) {}
    if (currentUserId == null || !mounted) return;

    final source = _photos[index.clamp(0, _photos.length - 1)];
    final rawAtt = source['attachment_id'] ?? source['id'];
    final attId = rawAtt is int ? rawAtt : int.tryParse('$rawAtt');
    var initial = 0;
    if (attId != null) {
      final found = galleryPhotos.indexWhere((p) => p['id'] == attId);
      if (found >= 0) initial = found;
    } else {
      initial = index.clamp(0, galleryPhotos.length - 1);
    }

    await GalleryPhotoViewerScreen.open(
      context,
      profileUserId: currentUserId,
      photo: galleryPhotos[initial],
      currentUserId: currentUserId,
      photos: galleryPhotos,
      initialIndex: initial,
    );
  }

  Future<void> _openEdit() async {
    if (!widget.canEdit) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChildMilestoneDetailScreen(
          code: widget.code,
          initial: _milestone,
          canEdit: true,
          childId: widget.childId,
          childName: widget.childName,
        ),
      ),
    );
    if (mounted) await _load();
  }

  void _openSlideshow() {
    final photos = _galleryPhotos;
    if (photos.length < 2) return;
    PhotoSlideshowScreen.open(
      context,
      photos: photos,
      startIndex: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fields = _filledFields;
    final photos = _photos;
    final canPlay = _galleryPhotos.length >= 2;
    const contentPad = EdgeInsets.symmetric(horizontal: 8);

    return Scaffold(
      appBar: FamilyAppBar.build(
        title: _title,
        actions: [
          if (widget.canEdit)
            IconButton(
              tooltip: 'Редактировать',
              onPressed: _milestone == null ? null : _openEdit,
              icon: const Icon(Icons.edit_outlined),
            ),
          if (canPlay)
            IconButton(
              tooltip: 'Диафильм',
              onPressed: _openSlideshow,
              icon: const Icon(Icons.play_circle_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Повторить'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (fields.isNotEmpty)
                        SliverPadding(
                          padding: contentPad.add(
                            const EdgeInsets.only(top: 12, bottom: 4),
                          ),
                          sliver: SliverToBoxAdapter(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerHighest
                                    .withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                child: Column(
                                  children: [
                                    for (var i = 0; i < fields.length; i++) ...[
                                      if (i > 0)
                                        Divider(
                                          height: 12,
                                          color: scheme.outlineVariant
                                              .withValues(alpha: 0.5),
                                        ),
                                      _CompactFieldTile(row: fields[i]),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (photos.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Text(
                              fields.isEmpty
                                  ? 'Нет заполненных данных'
                                  : 'Нет фото',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: contentPad.add(
                            const EdgeInsets.only(top: 4, bottom: 8),
                          ),
                          sliver: SliverGrid(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final photo = photos[index];
                                final canOpen = _galleryPhotos.isNotEmpty;
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: canOpen
                                      ? () => _openPhoto(index)
                                      : null,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      GalleryMediaThumbnail(
                                        attachment: photo,
                                        fit: BoxFit.cover,
                                      ),
                                      if (isVideoAttachment(photo))
                                        const ColoredBox(
                                          color: Color(0x33000000),
                                          child: Center(
                                            child: Icon(
                                              Icons.play_circle_outline,
                                              color: Colors.white70,
                                              size: 28,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                              childCount: photos.length,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

class _MilestoneFieldRow {
  const _MilestoneFieldRow({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;
}

class _CompactFieldTile extends StatelessWidget {
  const _CompactFieldTile({required this.row});

  final _MilestoneFieldRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(row.icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                row.value,
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
