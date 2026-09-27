import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/media_incoming_sync.dart';
import '../../../core/media/media_local_index.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/widgets/family_app_bar.dart';
import '../../gallery/presentation/gallery_media_thumbnail.dart';
import '../../profile/presentation/birthday_format.dart';
import '../../profile/presentation/gallery_photo_viewer_screen.dart';
import '../../profile/presentation/photo_slideshow_screen.dart';
import 'child_milestone_detail_screen.dart';
import 'scrapbook/utils/milestone_gallery_viewer.dart';
import 'scrapbook/utils/scrapbook_milestone_info.dart';
import 'scrapbook/widgets/scrapbook_milestone_media_viewer.dart';

/// Soft milestone accent — matches calendar baby-event chips.
const Color _kMilestoneAccent = Color(0xFFE8A0BF);

/// Просмотр заполненной вехи (только чтение): memory-first layout.
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
    extends ConsumerState<ChildMilestoneViewScreen>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic>? _milestone;
  DateTime? _birthDate;
  bool _loading = true;
  String? _error;
  late final AnimationController _enter;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic));
    _load();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _milestone == null;
      _error = null;
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      final results = await Future.wait<Object?>([
        repo.diaryMilestoneDetail(widget.code),
        repo.diaryBaby().catchError((_) => null),
      ]);
      if (!mounted) return;
      final m = results[0] as Map<String, dynamic>;
      final baby = results[1] as Map<String, dynamic>?;
      final photos = _photosOf(m);
      final galleryPhotos = milestonePhotosForGalleryViewer(photos);
      MediaLocalIndex.hydrateAttachments(galleryPhotos);
      unawaited(MediaIncomingSync.ensureGalleryPhotos(galleryPhotos));
      setState(() {
        _milestone = m;
        _birthDate = parseBirthDate(baby?['birth_date']?.toString()) ??
            parseBirthDate(baby?['birth_date_display']?.toString());
        _loading = false;
      });
      _enter.forward(from: 0);
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

  String? get _childName {
    final fromWidget = widget.childName?.trim();
    if (fromWidget != null && fromWidget.isNotEmpty) return fromWidget;
    return null;
  }

  List<Map<String, dynamic>> _photosOf(Map<String, dynamic>? m) {
    final raw = m?['photos'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  List<Map<String, dynamic>> get _photos => _photosOf(_milestone);

  List<Map<String, dynamic>> get _galleryPhotos =>
      milestonePhotosForGalleryViewer(_photos);

  String? get _dateLabel {
    final m = _milestone;
    if (m == null) return null;
    return scrapbookMilestoneAchievedDateLabel(m) ??
        (() {
          final achievedRaw = m['achieved_at']?.toString();
          final achievedAt = achievedRaw != null && achievedRaw.isNotEmpty
              ? DateTime.tryParse(achievedRaw)
              : null;
          if (achievedAt == null) return null;
          return DateFormat('d MMMM yyyy', 'ru').format(achievedAt);
        })();
  }

  String? get _ageLabel {
    final m = _milestone;
    if (m == null) return null;
    return scrapbookMilestoneAgeLabel(
      milestone: m,
      birthDate: _birthDate,
    );
  }

  String? get _note {
    final raw = _milestone?['note']?.toString().trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  String? get _weightLabel {
    final formatted = _formatNumber(_milestone?['weight_kg']);
    return formatted == null ? null : '$formatted кг';
  }

  String? get _heightLabel {
    final formatted = _formatNumber(_milestone?['height_cm']);
    return formatted == null ? null : '$formatted см';
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

  Map<String, dynamic> _thumbPayload(Map<String, dynamic> photo) {
    final identity = milestoneFamilyChatIdentity(photo);
    if (identity == null) return milestonePhotoForUrlViewer(photo);
    return {
      ...photo,
      'id': identity.attachmentId,
      'attachment_id': identity.attachmentId,
      'thread_id': identity.threadId,
    };
  }

  Future<void> _openPhoto(int index) async {
    final galleryPhotos = _galleryPhotos;
    if (galleryPhotos.isNotEmpty) {
      int? currentUserId;
      try {
        final status = await ref.read(familychatRepositoryProvider).status();
        final uid = status['user_id'];
        currentUserId = uid is int ? uid : int.tryParse('$uid');
      } catch (_) {}
      if (currentUserId != null && mounted) {
        final source = _photos[index.clamp(0, _photos.length - 1)];
        final identity = milestoneFamilyChatIdentity(source);
        var initial = index.clamp(0, galleryPhotos.length - 1);
        if (identity != null) {
          final found = galleryPhotos.indexWhere(
            (p) => p['id'] == identity.attachmentId,
          );
          if (found >= 0) initial = found;
        }

        await GalleryPhotoViewerScreen.open(
          context,
          profileUserId: currentUserId,
          photo: galleryPhotos[initial],
          currentUserId: currentUserId,
          photos: galleryPhotos,
          initialIndex: initial,
        );
        return;
      }
    }

    if (!mounted) return;
    await ScrapbookMilestoneMediaViewer.open(
      context,
      title: _title,
      media: _photos.map(milestonePhotoForUrlViewer).toList(),
      initialIndex: index,
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
    final photos = _photos;
    final canPlay = _galleryPhotos.length >= 2;
    final bg = Color.lerp(scheme.surface, _kMilestoneAccent, 0.06)!;

    return Scaffold(
      backgroundColor: bg,
      appBar: FamilyAppBar.build(
        title: _title,
        backgroundColor: bg,
        actions: [
          if (widget.canEdit)
            IconButton(
              tooltip: 'Редактировать',
              onPressed: _milestone == null ? null : _openEdit,
              icon: const Icon(LucideIcons.pencil),
            ),
          if (canPlay)
            IconButton(
              tooltip: 'Диафильм',
              onPressed: _openSlideshow,
              icon: const Icon(LucideIcons.circle_play),
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
                  color: _kMilestoneAccent,
                  child: FadeTransition(
                    opacity: _fade,
                    child: SlideTransition(
                      position: _slide,
                      child: CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            sliver: SliverList(
                              delegate: SliverChildListDelegate([
                                if (photos.isNotEmpty)
                                  _HeroPhoto(
                                    photo: photos.first,
                                    thumb: _thumbPayload(photos.first),
                                    onTap: () => _openPhoto(0),
                                  )
                                else
                                  const _EmptyHero(),
                                const SizedBox(height: 20),
                                _TitleBlock(
                                  title: _title,
                                  childName: _childName,
                                ),
                                if (_hasMeta) ...[
                                  const SizedBox(height: 14),
                                  _MetaChips(
                                    dateLabel: _dateLabel,
                                    ageLabel: _ageLabel,
                                    weightLabel: _weightLabel,
                                    heightLabel: _heightLabel,
                                  ),
                                ],
                                if (_note != null) ...[
                                  const SizedBox(height: 18),
                                  _NoteCard(note: _note!),
                                ],
                                if (photos.length > 1) ...[
                                  const SizedBox(height: 24),
                                  _GalleryHeader(count: photos.length - 1),
                                  const SizedBox(height: 12),
                                  _PhotoGrid(
                                    photos: photos.sublist(1),
                                    indexOffset: 1,
                                    thumbOf: _thumbPayload,
                                    onOpen: _openPhoto,
                                  ),
                                ] else if (photos.isEmpty && !_hasMeta) ...[
                                  const SizedBox(height: 32),
                                  Center(
                                    child: Text(
                                      'Нет заполненных данных',
                                      style: theme.textTheme.bodyLarge?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                ],
                              ]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
    );
  }

  bool get _hasMeta =>
      _dateLabel != null ||
      _ageLabel != null ||
      _weightLabel != null ||
      _heightLabel != null;
}

class _HeroPhoto extends StatelessWidget {
  const _HeroPhoto({
    required this.photo,
    required this.thumb,
    required this.onTap,
  });

  final Map<String, dynamic> photo;
  final Map<String, dynamic> thumb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final identity = milestoneFamilyChatIdentity(photo);
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: 4 / 5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: _kMilestoneAccent.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GalleryMediaThumbnail(
                  attachment: thumb,
                  threadId: identity?.threadId,
                  fit: BoxFit.cover,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x14000000),
                        Color(0x00000000),
                        Color(0x22000000),
                      ],
                      stops: [0, 0.45, 1],
                    ),
                  ),
                ),
                if (isVideoAttachment(photo))
                  const ColoredBox(
                    color: Color(0x33000000),
                    child: Center(
                      child: Icon(
                        LucideIcons.circle_play,
                        color: Colors.white,
                        size: 48,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyHero extends StatelessWidget {
  const _EmptyHero();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 4 / 5,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              _kMilestoneAccent.withValues(alpha: 0.35),
              scheme.surfaceContainerHighest.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: Center(
          child: Icon(
            LucideIcons.trophy,
            size: 56,
            color: scheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title, this.childName});

  final String title;
  final String? childName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.15,
            letterSpacing: -0.3,
          ),
        ),
        if (childName != null) ...[
          const SizedBox(height: 6),
          Text(
            childName!,
            style: theme.textTheme.titleMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

class _MetaChips extends StatelessWidget {
  const _MetaChips({
    this.dateLabel,
    this.ageLabel,
    this.weightLabel,
    this.heightLabel,
  });

  final String? dateLabel;
  final String? ageLabel;
  final String? weightLabel;
  final String? heightLabel;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (dateLabel != null)
          _Chip(icon: LucideIcons.calendar, label: dateLabel!),
        if (ageLabel != null)
          _Chip(icon: LucideIcons.baby, label: ageLabel!),
        if (weightLabel != null)
          _Chip(icon: LucideIcons.weight, label: weightLabel!),
        if (heightLabel != null)
          _Chip(icon: LucideIcons.ruler, label: heightLabel!),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: _kMilestoneAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: _kMilestoneAccent.withValues(alpha: 0.95)),
          const SizedBox(width: 7),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface.withValues(alpha: 0.88),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.quote,
                size: 16,
                color: _kMilestoneAccent.withValues(alpha: 0.9),
              ),
              const SizedBox(width: 8),
              Text(
                'Воспоминание',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            note,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      count == 1 ? 'Ещё фото' : 'Ещё фото · $count',
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
    );
  }
}

class _PhotoGrid extends StatelessWidget {
  const _PhotoGrid({
    required this.photos,
    required this.indexOffset,
    required this.thumbOf,
    required this.onOpen,
  });

  final List<Map<String, dynamic>> photos;
  final int indexOffset;
  final Map<String, dynamic> Function(Map<String, dynamic>) thumbOf;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: photos.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, i) {
        final photo = photos[i];
        final identity = milestoneFamilyChatIdentity(photo);
        final thumb = thumbOf(photo);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onOpen(indexOffset + i),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                GalleryMediaThumbnail(
                  attachment: thumb,
                  threadId: identity?.threadId,
                  fit: BoxFit.cover,
                ),
                if (isVideoAttachment(photo))
                  const ColoredBox(
                    color: Color(0x33000000),
                    child: Center(
                      child: Icon(
                        LucideIcons.circle_play,
                        color: Colors.white70,
                        size: 26,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
