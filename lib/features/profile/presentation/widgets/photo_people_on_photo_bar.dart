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
    required this.subjectKey,
    required this.boxes,
    this.userId,
    this.childId,
  });

  /// `user:{id}` или `child:{id}`.
  final String subjectKey;
  final List<PhotoFaceBox> boxes;
  final int? userId;
  final int? childId;
}

class _PhotoPerson {
  const _PhotoPerson({
    required this.subjectKey,
    required this.name,
    required this.avatarUrl,
    required this.boxes,
    this.userId,
    this.childId,
  });

  final String subjectKey;
  final String name;
  final String avatarUrl;
  final List<PhotoFaceBox> boxes;
  final int? userId;
  final int? childId;
}

PhotoFaceBox? photoFaceBoxFromMap(Map<String, dynamic> face) {
  final bbox = face['bbox'];
  if (bbox is! Map) return null;
  final x = (bbox['x'] as num?)?.toDouble() ?? 0;
  final y = (bbox['y'] as num?)?.toDouble() ?? 0;
  final w = (bbox['w'] as num?)?.toDouble() ?? 0;
  final h = (bbox['h'] as num?)?.toDouble() ?? 0;
  if (w <= 0 || h <= 0) return null;
  return PhotoFaceBox(x: x, y: y, w: w, h: h);
}

Future<List<_PhotoPerson>> loadRecognizedPeopleOnPhoto(
  WidgetRef ref, {
  required int attachmentId,
  int? profileUserId,
  int? threadId,
}) async {
  final repo = ref.read(familychatRepositoryProvider);
  late final Map<String, dynamic> data;
  if (profileUserId != null) {
    data = await repo.galleryPhotoFaces(profileUserId, attachmentId);
  } else if (threadId != null) {
    data = await repo.chatAttachmentFaces(threadId, attachmentId);
  } else {
    return const [];
  }

  final faces =
      (data['faces'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
  final byKey = <String, _PhotoPerson>{};
  for (final face in faces) {
    final childRaw = face['assigned_child_id'];
    final childId = childRaw is int ? childRaw : int.tryParse('$childRaw');
    final userRaw = face['assigned_user_id'];
    final userId = userRaw is int ? userRaw : int.tryParse('$userRaw');
    final String subjectKey;
    if (childId != null) {
      subjectKey = 'child:$childId';
    } else if (userId != null) {
      subjectKey = 'user:$userId';
    } else {
      continue;
    }
    final name = (face['assigned_display_name']?.toString() ?? '').trim();
    if (name.isEmpty) continue;
    final box = photoFaceBoxFromMap(face);
    final existing = byKey[subjectKey];
    if (existing == null) {
      byKey[subjectKey] = _PhotoPerson(
        subjectKey: subjectKey,
        userId: userId,
        childId: childId,
        name: name,
        avatarUrl: face['assigned_avatar_url']?.toString() ?? '',
        boxes: box == null ? const [] : [box],
      );
    } else if (box != null) {
      byKey[subjectKey] = _PhotoPerson(
        subjectKey: existing.subjectKey,
        userId: existing.userId,
        childId: existing.childId,
        name: existing.name,
        avatarUrl: existing.avatarUrl,
        boxes: [...existing.boxes, box],
      );
    }
  }
  final people = byKey.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
}

/// Кнопка «?» в углу фото + раскрывающийся список узнанных людей.
class PhotoPeopleOnPhotoOverlay extends ConsumerStatefulWidget {
  const PhotoPeopleOnPhotoOverlay({
    super.key,
    required this.attachmentId,
    this.profileUserId,
    this.threadId,
    this.selectedSubjectKey,
    @Deprecated('Use selectedSubjectKey') this.selectedUserId,
    this.onHighlightChanged,
  });

  final int attachmentId;
  final int? profileUserId;
  final int? threadId;
  final String? selectedSubjectKey;
  final int? selectedUserId;
  final ValueChanged<PhotoPersonHighlight?>? onHighlightChanged;

  @override
  ConsumerState<PhotoPeopleOnPhotoOverlay> createState() =>
      _PhotoPeopleOnPhotoOverlayState();
}

class _PhotoPeopleOnPhotoOverlayState
    extends ConsumerState<PhotoPeopleOnPhotoOverlay> {
  bool _loading = true;
  bool _expanded = false;
  List<_PhotoPerson> _people = const [];

  String? get _selectedKey {
    if (widget.selectedSubjectKey != null) return widget.selectedSubjectKey;
    final uid = widget.selectedUserId;
    if (uid != null) return 'user:$uid';
    return null;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PhotoPeopleOnPhotoOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachmentId != widget.attachmentId ||
        oldWidget.profileUserId != widget.profileUserId ||
        oldWidget.threadId != widget.threadId) {
      _expanded = false;
      widget.onHighlightChanged?.call(null);
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _people = const [];
      _expanded = false;
    });
    try {
      final people = await loadRecognizedPeopleOnPhoto(
        ref,
        attachmentId: widget.attachmentId,
        profileUserId: widget.profileUserId,
        threadId: widget.threadId,
      );
      if (!mounted) return;
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
    final selected = _selectedKey == person.subjectKey;
    if (selected) {
      widget.onHighlightChanged?.call(null);
      return;
    }
    widget.onHighlightChanged?.call(
      PhotoPersonHighlight(
        subjectKey: person.subjectKey,
        userId: person.userId,
        childId: person.childId,
        boxes: person.boxes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _people.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned(
      top: 8,
      right: 8,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: Colors.black.withValues(alpha: 0.55),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _expanded = !_expanded),
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: Text(
                      '?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: _expanded
                  ? Padding(
                      key: const ValueKey('people-panel'),
                      padding: const EdgeInsets.only(top: 8),
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.88),
                        elevation: 6,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: 280,
                            maxHeight: 240,
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            itemCount: _people.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 6),
                            itemBuilder: (_, i) {
                              final person = _people[i];
                              final selected =
                                  _selectedKey == person.subjectKey;
                              return Material(
                                color: selected
                                    ? const Color(0xFF2E7D32)
                                        .withValues(alpha: 0.35)
                                    : Colors.white.withValues(alpha: 0.1),
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
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
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
                                          Flexible(
                                            child: Text(
                                              person.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                              ),
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
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('people-panel-hidden')),
            ),
          ],
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
