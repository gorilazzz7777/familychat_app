import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/media/gallery_photo_date.dart';

/// Оверлей скраббера как в Google Photos:
/// ручка всегда показывает позицию; при драге — годы + месяц;
/// скролл плавно по смещению; haptic при смене дня.
class GalleryDateScrubber extends StatefulWidget {
  const GalleryDateScrubber({
    super.key,
    required this.sections,
    required this.scrollController,
  });

  final List<GalleryAlbumDaySection> sections;
  final ScrollController scrollController;

  @override
  State<GalleryDateScrubber> createState() => _GalleryDateScrubberState();
}

class _YearMark {
  const _YearMark({required this.year, required this.fraction});
  final int year;
  final double fraction;
}

class _GalleryDateScrubberState extends State<GalleryDateScrubber> {
  static const _trackWidth = 64.0;
  static const _handleWidth = 28.0;
  static const _handleHeight = 44.0;
  static const _vPad = 20.0;

  bool _dragging = false;
  double _handleY = 0;
  int _activeSection = 0;
  String? _activeDayKey;
  Timer? _settleTimer;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromScroll());
  }

  @override
  void didUpdateWidget(covariant GalleryDateScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (oldWidget.sections != widget.sections && !_dragging) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromScroll());
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  int get _photoCount {
    var n = 0;
    for (final s in widget.sections) {
      n += s.photos.length;
    }
    return n;
  }

  List<_YearMark> get _yearMarks {
    if (widget.sections.isEmpty) return const [];
    final out = <_YearMark>[];
    final seen = <int>{};
    final total = math.max(1, widget.sections.length - 1);
    for (var i = 0; i < widget.sections.length; i++) {
      final y = widget.sections[i].date.year;
      if (seen.add(y)) {
        out.add(_YearMark(year: y, fraction: i / total));
      }
    }
    return out;
  }

  int _sectionIndexForPhotoIndex(int photoIndex) {
    var remaining = photoIndex;
    for (var i = 0; i < widget.sections.length; i++) {
      final len = widget.sections[i].photos.length;
      if (remaining < len) return i;
      remaining -= len;
    }
    return widget.sections.isEmpty ? 0 : widget.sections.length - 1;
  }

  int _photoIndexForFraction(double fraction) {
    final n = _photoCount;
    if (n <= 1) return 0;
    return (fraction.clamp(0.0, 1.0) * (n - 1)).round();
  }

  double _scrollFraction() {
    if (!widget.scrollController.hasClients) return 0;
    final max = widget.scrollController.position.maxScrollExtent;
    if (max <= 0) return 0;
    return (widget.scrollController.offset / max).clamp(0.0, 1.0);
  }

  void _applySection(int sectionIndex, {required bool haptic}) {
    if (sectionIndex < 0 || sectionIndex >= widget.sections.length) return;
    final section = widget.sections[sectionIndex];
    final dayChanged = _activeDayKey != section.dayKey;
    if (sectionIndex == _activeSection && !dayChanged) return;
    setState(() {
      _activeSection = sectionIndex;
      _activeDayKey = section.dayKey;
    });
    if (haptic && dayChanged) {
      HapticFeedback.selectionClick();
    }
  }

  void _scrollToFraction(double fraction, {required bool animated}) {
    if (!widget.scrollController.hasClients) return;
    final max = widget.scrollController.position.maxScrollExtent;
    final target = fraction.clamp(0.0, 1.0) * max;
    if (!animated) {
      widget.scrollController.jumpTo(target);
      return;
    }
    unawaited(
      widget.scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  void _onScroll() {
    if (_dragging) return;
    _syncFromScroll();
  }

  void _syncFromScroll() {
    if (!mounted || widget.sections.isEmpty) return;
    if (!widget.scrollController.hasClients) return;
    final fraction = _scrollFraction();
    final trackH = _trackHeightForContext();
    final photoIndex = _photoIndexForFraction(fraction);
    final sectionIndex = _sectionIndexForPhotoIndex(photoIndex);
    final newY = fraction * trackH;
    final dayKey = widget.sections[sectionIndex].dayKey;
    if ((newY - _handleY).abs() < 0.5 &&
        sectionIndex == _activeSection &&
        dayKey == _activeDayKey) {
      return;
    }
    setState(() {
      _handleY = newY;
      _activeSection = sectionIndex;
      _activeDayKey = dayKey;
    });
  }

  double _trackHeightForContext() {
    final h = MediaQuery.sizeOf(context).height;
    return math.max(1.0, h - 160);
  }

  void _onDragUpdate(double localY, double trackHeight) {
    final y = localY.clamp(0.0, trackHeight);
    final fraction = trackHeight <= 0 ? 0.0 : y / trackHeight;
    setState(() => _handleY = y);

    // Плавное следование за пальцем по всему контенту (не прыжок день→день).
    _scrollToFraction(fraction, animated: false);

    final photoIndex = _photoIndexForFraction(fraction);
    final sectionIndex = _sectionIndexForPhotoIndex(photoIndex);
    _applySection(sectionIndex, haptic: true);
  }

  void _onDragEnd(double trackHeight) {
    setState(() => _dragging = false);
    // Мягко дотягиваем к текущей позиции (визуальный settle).
    final fraction = trackHeight <= 0 ? 0.0 : (_handleY / trackHeight);
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 16), () {
      if (!mounted) return;
      _scrollToFraction(fraction, animated: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sections.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final section =
        widget.sections[_activeSection.clamp(0, widget.sections.length - 1)];
    final topLabel = galleryPhotoTopDateLabel(section.date);
    final monthLabel = galleryPhotoScrubMonthLabel(section.date);
    final years = _yearMarks;
    const pillBg = Color(0xE6333333);
    const pillFg = Colors.white;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = math.max(1.0, constraints.maxHeight - _vPad * 2);

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: IgnorePointer(
                child: Center(
                  child: Material(
                    color: pillBg,
                    borderRadius: BorderRadius.circular(20),
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Text(
                        topLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: pillFg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            Positioned(
              top: _vPad,
              right: 0,
              bottom: _vPad,
              width: _trackWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: (d) {
                  _settleTimer?.cancel();
                  setState(() {
                    _dragging = true;
                    _handleY = d.localPosition.dy.clamp(0.0, trackHeight);
                  });
                  _onDragUpdate(d.localPosition.dy, trackHeight);
                },
                onVerticalDragUpdate: (d) {
                  _onDragUpdate(d.localPosition.dy, trackHeight);
                },
                onVerticalDragEnd: (_) => _onDragEnd(trackHeight),
                onVerticalDragCancel: () {
                  setState(() => _dragging = false);
                },
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_dragging) ...[
                      for (final mark in years)
                        Positioned(
                          right: _handleWidth + 8,
                          top: mark.fraction * trackHeight - 10,
                          child: Material(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              child: Text(
                                '${mark.year}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        right: _handleWidth + 10,
                        top: (_handleY - 16).clamp(0.0, trackHeight - 32),
                        child: Material(
                          color: pillBg,
                          borderRadius: BorderRadius.circular(18),
                          elevation: 3,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(
                              monthLabel,
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: pillFg,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],

                    // Ручка позиции — всегда видна; её и двигаем.
                    Positioned(
                      right: 6,
                      top: (_handleY - _handleHeight / 2)
                          .clamp(0.0, trackHeight - _handleHeight),
                      child: AnimatedOpacity(
                        opacity: _dragging ? 1 : 0.72,
                        duration: const Duration(milliseconds: 150),
                        child: Material(
                          color: pillBg,
                          borderRadius: BorderRadius.circular(16),
                          elevation: _dragging ? 4 : 2,
                          child: const SizedBox(
                            width: _handleWidth,
                            height: _handleHeight,
                            child: Icon(
                              Icons.unfold_more,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
