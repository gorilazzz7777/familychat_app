import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/app_providers.dart';
import 'chat_avatar.dart';

class PhotoFaceBox {
  const PhotoFaceBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  /// Нормализованные координаты 0..1 относительно кадра фото.
  final double x;
  final double y;
  final double w;
  final double h;
}

class PhotoPersonHighlight {
  const PhotoPersonHighlight({
    required this.userId,
    required this.boxes,
  });

  final int userId;
  final List<PhotoFaceBox> boxes;
}

class _PhotoPerson {
  const _PhotoPerson({
    required this.userId,
    required this.name,
    required this.avatarUrl,
    required this.boxes,
  });

  final int userId;
  final String name;
  final String avatarUrl;
  final List<PhotoFaceBox> boxes;
}

/// Блок «Кто на фото» внизу полноэкранного просмотра.
/// Высота всегда фиксирована (loading / пусто / люди), чтобы фото не прыгало.
/// Тап по человеку — подсветка лица на фото (не переход в профиль).
class PhotoPeopleOnPhotoBar extends ConsumerStatefulWidget {
  const PhotoPeopleOnPhotoBar({
    super.key,
    required this.attachmentId,
    this.profileUserId,
    this.threadId,
    this.selectedUserId,
    this.onHighlightChanged,
  });

  final int attachmentId;
  final int? profileUserId;
  final int? threadId;
  final int? selectedUserId;
  final ValueChanged<PhotoPersonHighlight?>? onHighlightChanged;

  /// Заголовок + отступ + ряд аватаров (без внешних паддингов).
  static const double contentHeight = 74;

  @override
  ConsumerState<PhotoPeopleOnPhotoBar> createState() =>
      _PhotoPeopleOnPhotoBarState();
}

class _PhotoPeopleOnPhotoBarState extends ConsumerState<PhotoPeopleOnPhotoBar> {
  bool _loading = true;
  List<_PhotoPerson> _people = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoPeopleOnPhotoBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        oldWidget.profileUserId != widget.profileUserId ||
        oldWidget.threadId != widget.threadId) {
      widget.onHighlightChanged?.call(null);
      _load();
    }
  }

  PhotoFaceBox? _boxFromFace(Map<String, dynamic> face) {
    final bbox = face['bbox'];
    if (bbox is! Map) return null;
    final x = (bbox['x'] as num?)?.toDouble() ?? 0;
    final y = (bbox['y'] as num?)?.toDouble() ?? 0;
    final w = (bbox['w'] as num?)?.toDouble() ?? 0;
    final h = (bbox['h'] as num?)?.toDouble() ?? 0;
    if (w <= 0 || h <= 0) return null;
    return PhotoFaceBox(x: x, y: y, w: w, h: h);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _people = const [];
    });
    try {
      final repo = ref.read(familychatRepositoryProvider);
      late final Map<String, dynamic> data;
      if (widget.profileUserId != null) {
        data = await repo.galleryPhotoFaces(
            widget.profileUserId!, widget.attachmentId);
      } else if (widget.threadId != null) {
        data = await repo.chatAttachmentFaces(
            widget.threadId!, widget.attachmentId);
      } else {
        if (mounted) setState(() => _loading = false);
        return;
      }
      if (!mounted) return;
      final faces =
          (data['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      final byUserId = <int, _PhotoPerson>{};
      for (final face in faces) {
        final rawId = face['assigned_user_id'];
        final userId = rawId is int ? rawId : int.tryParse('$rawId');
        if (userId == null) continue;
        final name = (face['assigned_display_name']?.toString() ?? '').trim();
        if (name.isEmpty) continue;
        final box = _boxFromFace(face);
        final existing = byUserId[userId];
        if (existing == null) {
          byUserId[userId] = _PhotoPerson(
            userId: userId,
            name: name,
            avatarUrl: face['assigned_avatar_url']?.toString() ?? '',
            boxes: box == null ? const [] : [box],
          );
        } else if (box != null) {
          byUserId[userId] = _PhotoPerson(
            userId: existing.userId,
            name: existing.name,
            avatarUrl: existing.avatarUrl,
            boxes: [...existing.boxes, box],
          );
        }
      }
      final people = byUserId.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() {
        _people = people;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _people = const [];
        _loading = false;
      });
    }
  }

  void _onPersonTap(_PhotoPerson person) {
    final selected = widget.selectedUserId == person.userId;
    if (selected) {
      widget.onHighlightChanged?.call(null);
      return;
    }
    widget.onHighlightChanged?.call(
      PhotoPersonHighlight(userId: person.userId, boxes: person.boxes),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: SizedBox(
          height: PhotoPeopleOnPhotoBar.contentHeight,
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 20,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: (!_loading && _people.isNotEmpty)
                      ? Text(
                          'Кто на фото',
                          style:
                              Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                  ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 44,
                child: _loading
                    ? const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white54,
                          ),
                        ),
                      )
                    : _people.isEmpty
                        ? const SizedBox.expand()
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _people.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 10),
                            itemBuilder: (_, i) {
                              final person = _people[i];
                              final selected =
                                  widget.selectedUserId == person.userId;
                              return Material(
                                color: selected
                                    ? const Color(0xFF2E7D32)
                                        .withValues(alpha: 0.35)
                                    : Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(24),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => _onPersonTap(person),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: selected
                                            ? const Color(0xFF69F0AE)
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 6),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          ChatAvatar(
                                            name: person.name,
                                            avatarUrl: person.avatarUrl.isEmpty
                                                ? null
                                                : person.avatarUrl,
                                            radius: 16,
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            person.name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Зелёные рамки лиц поверх фото (нормализованные bbox 0..1).
class PhotoFaceHighlightOverlay extends StatelessWidget {
  const PhotoFaceHighlightOverlay({
    super.key,
    required this.boxes,
  });

  final List<PhotoFaceBox> boxes;

  static const Color _border = Color(0xFF69F0AE);

  @override
  Widget build(BuildContext context) {
    if (boxes.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final boxH = constraints.maxHeight;
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final box in boxes)
                Positioned(
                  left: box.x * boxW,
                  top: box.y * boxH,
                  width: box.w * boxW,
                  height: box.h * boxH,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: _border, width: 3),
                      borderRadius: BorderRadius.circular(6),
                      color: _border.withValues(alpha: 0.12),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
