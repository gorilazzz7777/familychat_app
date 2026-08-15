import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../../core/media/gallery_media_utils.dart';
import '../utils/scrapbook_media_layout_store.dart';
import 'scrapbook_kraft_background.dart';
import 'scrapbook_milestone_slot.dart';

enum ScrapbookLayoutTool { transform, rotate }

/// Редактор положения/размера/поворота фото в том же масштабе, что страница альбома.
class ScrapbookLayoutEditor extends StatefulWidget {
  const ScrapbookLayoutEditor({
    super.key,
    required this.request,
    required this.onDone,
    this.tool = ScrapbookLayoutTool.transform,
  });

  final ScrapbookLayoutEditRequest request;
  final Future<void> Function(Map<String, ScrapbookMediaRect> layouts) onDone;
  final ScrapbookLayoutTool tool;

  @override
  ScrapbookLayoutEditorState createState() => ScrapbookLayoutEditorState();
}

class ScrapbookLayoutEditorState extends State<ScrapbookLayoutEditor> {
  static const _handleHit = 56.0;
  static const _handleVisual = 30.0;
  static const _minWidthPx = 64.0;

  late Map<String, ScrapbookMediaRect> _layouts;
  int _selected = 0;
  bool _saving = false;

  final ValueNotifier<_LiveDrag?> _live = ValueNotifier<_LiveDrag?>(null);
  final GlobalKey _mediaKey = GlobalKey();

  Size? _mediaArea;

  @override
  void initState() {
    super.initState();
    _layouts = Map<String, ScrapbookMediaRect>.from(widget.request.layouts);
    final maxIndex = (widget.request.media.length - 1).clamp(0, 5);
    _selected = widget.request.initialSelectedIndex.clamp(0, maxIndex);
  }

  @override
  void didUpdateWidget(covariant ScrapbookLayoutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool != widget.tool) {
      final area = _mediaArea;
      if (area != null && _live.value != null) {
        _endLive(area);
      }
    }
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  Future<void> commit() => _done();

  bool get _isRotateTool => widget.tool == ScrapbookLayoutTool.rotate;

  String _keyAt(int index) =>
      scrapbookMediaLayoutKey(widget.request.media[index]);

  double _aspectAt(int index) {
    if (index < 0 || index >= widget.request.aspects.length) return 1;
    final a = widget.request.aspects[index];
    return a <= 0 ? 1 : a;
  }

  double _rotationAt(int index) =>
      _layouts[_keyAt(index)]?.rotationDeg ?? 0;

  Offset? _mediaLocal(Offset global) {
    final box = _mediaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(global);
  }

  RectPx _committedPx(int index, Size area) {
    final key = _keyAt(index);
    final rect = _layouts[key];
    if (rect == null) {
      return RectPx(
        left: 0,
        top: 0,
        width: area.width * 0.4,
        height: area.width * 0.4 / _aspectAt(index),
      );
    }
    return rect.toPixels(
      aspect: _aspectAt(index),
      containerW: area.width,
      containerH: area.height,
    );
  }

  void _ensureDefaults(Size area) {
    if (_layouts.length >= widget.request.media.length.clamp(0, 6)) return;
    final defaults = ScrapbookMediaLayoutStore.defaultLayouts(
      media: widget.request.media.take(6).toList(),
      aspects: widget.request.aspects,
      containerW: area.width,
      containerH: area.height,
    );
    var changed = false;
    for (final e in defaults.entries) {
      if (!_layouts.containsKey(e.key)) {
        _layouts[e.key] = e.value;
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  void _commit(int index, RectPx px, Size area, double rotationDeg) {
    final clamped = px.clampedTo(area.width, area.height);
    final key = _keyAt(index);
    final aspect = _aspectAt(index);
    _layouts[key] = ScrapbookMediaRect.fromPixels(
      rect: clamped,
      containerW: area.width,
      containerH: area.height,
      rotationDeg: rotationDeg,
      aspect: aspect,
    );
  }

  void _beginMove(int index, Size area) {
    _live.value = _LiveDrag(
      index: index,
      rect: _committedPx(index, area),
      rotationDeg: _rotationAt(index),
      mode: _DragMode.move,
    );
  }

  void _beginScale(int index, Size area, _Corner corner) {
    _live.value = _LiveDrag(
      index: index,
      rect: _committedPx(index, area),
      rotationDeg: _rotationAt(index),
      mode: _DragMode.scale,
      corner: corner,
    );
  }

  void _beginRotate(int index, Size area, Offset mediaLocal) {
    final rect = _committedPx(index, area);
    final center = Offset(
      rect.left + rect.width / 2,
      rect.top + rect.height / 2,
    );
    final startAngle = math.atan2(
      mediaLocal.dy - center.dy,
      mediaLocal.dx - center.dx,
    );
    final base = _rotationAt(index);
    _live.value = _LiveDrag(
      index: index,
      rect: rect,
      rotationDeg: base,
      mode: _DragMode.rotate,
      rotatePointerStart: startAngle,
      rotateBaseDeg: base,
    );
  }

  void _updateLive(Offset delta, Size area, {Offset? mediaLocal}) {
    final live = _live.value;
    if (live == null) return;

    switch (live.mode) {
      case _DragMode.move:
        final next = live.rect.copyWith(
          left: live.rect.left + delta.dx,
          top: live.rect.top + delta.dy,
        );
        _live.value = live.copyWith(
          rect: next.clampedTo(area.width, area.height),
        );
      case _DragMode.scale:
        final next = _scaleRect(
          live.rect,
          live.corner ?? _Corner.bottomRight,
          delta.dx,
          delta.dy,
          _aspectAt(live.index),
        );
        _live.value = live.copyWith(
          rect: next.clampedTo(area.width, area.height),
        );
      case _DragMode.rotate:
        if (mediaLocal == null) return;
        final center = Offset(
          live.rect.left + live.rect.width / 2,
          live.rect.top + live.rect.height / 2,
        );
        final angle = math.atan2(
          mediaLocal.dy - center.dy,
          mediaLocal.dx - center.dx,
        );
        final start = live.rotatePointerStart ?? angle;
        final base = live.rotateBaseDeg ?? live.rotationDeg;
        _live.value = live.copyWith(
          rotationDeg: base + (angle - start) * 180 / math.pi,
        );
    }
  }

  void _endLive(Size area) {
    final live = _live.value;
    if (live == null) return;
    _commit(live.index, live.rect, area, live.rotationDeg);
    _live.value = null;
    setState(() {});
  }

  RectPx _scaleRect(
    RectPx px,
    _Corner corner,
    double dx,
    double dy,
    double aspect,
  ) {
    var nextW = px.width;
    var nextL = px.left;
    var nextT = px.top;

    switch (corner) {
      case _Corner.bottomRight:
        nextW = px.width + dx;
      case _Corner.bottomLeft:
        nextW = px.width - dx;
        nextL = px.left + dx;
      case _Corner.topRight:
        nextW = px.width + dx;
        nextT = px.bottom - (nextW / aspect);
      case _Corner.topLeft:
        nextW = px.width - dx;
        nextL = px.left + dx;
        nextT = px.bottom - (nextW / aspect);
    }

    if (nextW < _minWidthPx) {
      final fixedW = _minWidthPx;
      switch (corner) {
        case _Corner.bottomRight:
          nextW = fixedW;
        case _Corner.bottomLeft:
          nextL = px.right - fixedW;
          nextW = fixedW;
        case _Corner.topRight:
          nextW = fixedW;
          nextT = px.bottom - fixedW / aspect;
        case _Corner.topLeft:
          nextL = px.right - fixedW;
          nextW = fixedW;
          nextT = px.bottom - fixedW / aspect;
      }
    }

    return RectPx(
      left: nextL,
      top: nextT,
      width: nextW,
      height: nextW / aspect,
    );
  }

  Future<void> _done() async {
    if (_saving) return;
    final area = _mediaArea;
    if (area != null && _live.value != null) {
      _endLive(area);
    }
    setState(() => _saving = true);
    try {
      await widget.onDone(_layouts);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  int get _mediaFlex {
    final n = widget.request.media.length;
    if (!_hasNote) return 1;
    if (n <= 1) return 5;
    if (n <= 3) return 6;
    return 7;
  }

  int get _commentFlex {
    final n = widget.request.media.length;
    if (n <= 3) return 3;
    return 2;
  }

  bool get _hasNote {
    final note = widget.request.note?.trim() ?? '';
    return note.isNotEmpty;
  }

  bool get _hasMeta {
    final req = widget.request;
    return req.weightLabel != null ||
        req.heightLabel != null ||
        req.ageLabel != null;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.request.media.length.clamp(0, 6);
    final req = widget.request;

    return Material(
      color: ScrapbookKraftBackground.deskColor,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
          child: ScrapbookKraftBackground(
            padding: const EdgeInsets.all(10),
            showSpine: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      req.milestoneTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.merriweather(
                        fontSize: 20,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF4A3728),
                      ),
                    ),
                    if (req.dateLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        req.dateLabel!,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.caveat(
                          fontSize: 17,
                          color: const Color(0xFF7A5C44),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Expanded(
                      flex: _mediaFlex,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final area = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          _mediaArea = area;
                          SchedulerBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _ensureDefaults(area);
                          });

                          return Stack(
                            key: _mediaKey,
                            clipBehavior: Clip.none,
                            children: [
                              for (var i = 0; i < count; i++)
                                if (i == _selected)
                                  _SelectedItemLayer(
                                    live: _live,
                                    index: i,
                                    committedPx: () => _committedPx(i, area),
                                    committedRotation: () => _rotationAt(i),
                                    isRotateTool: _isRotateTool,
                                    handleHit: _handleHit,
                                    handleVisual: _handleVisual,
                                    content: _photoContent(
                                      i,
                                      area,
                                      selected: true,
                                    ),
                                    onScaleStart: (corner) =>
                                        _beginScale(i, area, corner),
                                    onScaleUpdate: (dx, dy) =>
                                        _updateLive(Offset(dx, dy), area),
                                    onScaleEnd: () => _endLive(area),
                                  )
                                else
                                  _photoPositioned(
                                    i,
                                    area,
                                    selected: false,
                                  ),
                            ],
                          );
                        },
                      ),
                    ),
                    if (_hasNote) ...[
                      const SizedBox(height: 12),
                      Expanded(
                        flex: _commentFlex,
                        child: _ReadonlyComment(
                          note: req.note,
                          ageLabel: req.ageLabel,
                          weightLabel: req.weightLabel,
                          heightLabel: req.heightLabel,
                        ),
                      ),
                    ] else if (_hasMeta) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 2,
                        children: [
                          if (req.weightLabel != null)
                            Text(
                              'Мой вес: ${req.weightLabel}',
                              style: GoogleFonts.caveat(
                                fontSize: 16,
                                color: const Color(0xFF4A3728),
                              ),
                            ),
                          if (req.heightLabel != null)
                            Text(
                              'Мой рост: ${req.heightLabel}',
                              style: GoogleFonts.caveat(
                                fontSize: 16,
                                color: const Color(0xFF4A3728),
                              ),
                            ),
                          if (req.ageLabel != null)
                            Text(
                              'Мой возраст: ${req.ageLabel}',
                              style: GoogleFonts.caveat(
                                fontSize: 16,
                                color: const Color(0xFF4A3728),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _photoContent(int index, Size area, {required bool selected}) {
    final isVideo = isVideoAttachment(widget.request.media[index]);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              if (_selected != index) {
                setState(() => _selected = index);
                return;
              }
              if (_isRotateTool) {
                final local = _mediaLocal(e.position);
                if (local != null) _beginRotate(index, area, local);
              } else {
                _beginMove(index, area);
              }
            },
            onPointerMove: (e) {
              if (!selected) return;
              final live = _live.value;
              if (live == null || live.index != index) return;
              if (live.mode == _DragMode.rotate) {
                final local = _mediaLocal(e.position);
                _updateLive(e.delta, area, mediaLocal: local);
              } else if (live.mode == _DragMode.move) {
                _updateLive(e.delta, area);
              }
            },
            onPointerUp: (_) {
              if (selected) _endLive(area);
            },
            onPointerCancel: (_) {
              if (selected) _endLive(area);
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: selected
                    ? Border.all(
                        color: _isRotateTool
                            ? const Color(0xFFC47A3A)
                            : const Color(0xFF5B8C5A),
                        width: 2,
                      )
                    : null,
              ),
              child: RepaintBoundary(
                child: AgedMediaFrame(
                  attachment: widget.request.media[index],
                ),
              ),
            ),
          ),
        ),
        if (isVideo)
          const IgnorePointer(
            child: Center(
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white70,
                size: 28,
              ),
            ),
          ),
        if (selected && _isRotateTool)
          const IgnorePointer(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.only(top: 6),
                child: Icon(
                  Icons.rotate_right,
                  color: Color(0xFFC47A3A),
                  size: 22,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _photoPositioned(int index, Size area, {required bool selected}) {
    final px = _committedPx(index, area);
    final rot = _rotationAt(index);
    return Positioned(
      left: px.left,
      top: px.top,
      width: px.width,
      height: px.height,
      child: Transform.rotate(
        angle: rot * math.pi / 180,
        child: _photoContent(index, area, selected: selected),
      ),
    );
  }
}

/// Selected photo + oversized corner handles live in media coordinates.
class _SelectedItemLayer extends StatelessWidget {
  const _SelectedItemLayer({
    required this.live,
    required this.index,
    required this.committedPx,
    required this.committedRotation,
    required this.isRotateTool,
    required this.handleHit,
    required this.handleVisual,
    required this.content,
    required this.onScaleStart,
    required this.onScaleUpdate,
    required this.onScaleEnd,
  });

  final ValueNotifier<_LiveDrag?> live;
  final int index;
  final RectPx Function() committedPx;
  final double Function() committedRotation;
  final bool isRotateTool;
  final double handleHit;
  final double handleVisual;
  final Widget content;
  final void Function(_Corner corner) onScaleStart;
  final void Function(double dx, double dy) onScaleUpdate;
  final VoidCallback onScaleEnd;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ValueListenableBuilder<_LiveDrag?>(
        valueListenable: live,
        builder: (context, drag, child) {
          final active = drag != null && drag.index == index;
          final px = active ? drag.rect : committedPx();
          final rot = active ? drag.rotationDeg : committedRotation();

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: px.left,
                top: px.top,
                width: px.width,
                height: px.height,
                child: Transform.rotate(
                  angle: rot * math.pi / 180,
                  child: child,
                ),
              ),
              if (!isRotateTool)
                for (final corner in _Corner.values)
                  Positioned(
                    left: corner.pointOn(px).dx - handleHit / 2,
                    top: corner.pointOn(px).dy - handleHit / 2,
                    width: handleHit,
                    height: handleHit,
                    child: _ScaleHandle(
                      visualSize: handleVisual,
                      onPanStart: () => onScaleStart(corner),
                      onPanUpdate: onScaleUpdate,
                      onPanEnd: onScaleEnd,
                    ),
                  ),
            ],
          );
        },
        child: content,
      ),
    );
  }
}

class _ReadonlyComment extends StatelessWidget {
  const _ReadonlyComment({
    this.note,
    this.ageLabel,
    this.weightLabel,
    this.heightLabel,
  });

  final String? note;
  final String? ageLabel;
  final String? weightLabel;
  final String? heightLabel;

  @override
  Widget build(BuildContext context) {
    final hasNote = note != null && note!.isNotEmpty;
    if (!hasNote) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: CustomPaint(
            painter: const ScrapbookLinedPaperPainter(
              lineHeight: 22,
              topPad: 20,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Text(
                note!,
                style: GoogleFonts.caveat(
                  fontSize: 18,
                  height: 22 / 18,
                  color: const Color(0xFF3F2E22),
                ),
              ),
            ),
          ),
        ),
        if (weightLabel != null || heightLabel != null || ageLabel != null) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              if (weightLabel != null)
                Text(
                  'Мой вес: $weightLabel',
                  style: GoogleFonts.caveat(
                    fontSize: 16,
                    color: const Color(0xFF4A3728),
                  ),
                ),
              if (heightLabel != null)
                Text(
                  'Мой рост: $heightLabel',
                  style: GoogleFonts.caveat(
                    fontSize: 16,
                    color: const Color(0xFF4A3728),
                  ),
                ),
              if (ageLabel != null)
                Text(
                  'Мой возраст: $ageLabel',
                  style: GoogleFonts.caveat(
                    fontSize: 16,
                    color: const Color(0xFF4A3728),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

enum _DragMode { move, scale, rotate }

class _LiveDrag {
  const _LiveDrag({
    required this.index,
    required this.rect,
    required this.rotationDeg,
    required this.mode,
    this.corner,
    this.rotatePointerStart,
    this.rotateBaseDeg,
  });

  final int index;
  final RectPx rect;
  final double rotationDeg;
  final _DragMode mode;
  final _Corner? corner;
  final double? rotatePointerStart;
  final double? rotateBaseDeg;

  _LiveDrag copyWith({
    RectPx? rect,
    double? rotationDeg,
  }) {
    return _LiveDrag(
      index: index,
      rect: rect ?? this.rect,
      rotationDeg: rotationDeg ?? this.rotationDeg,
      mode: mode,
      corner: corner,
      rotatePointerStart: rotatePointerStart,
      rotateBaseDeg: rotateBaseDeg,
    );
  }
}

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

extension on _Corner {
  Offset pointOn(RectPx px) => switch (this) {
        _Corner.topLeft => Offset(px.left, px.top),
        _Corner.topRight => Offset(px.right, px.top),
        _Corner.bottomLeft => Offset(px.left, px.bottom),
        _Corner.bottomRight => Offset(px.right, px.bottom),
      };
}

class _ScaleHandle extends StatelessWidget {
  const _ScaleHandle({
    required this.visualSize,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  final double visualSize;
  final VoidCallback onPanStart;
  final void Function(double dx, double dy) onPanUpdate;
  final VoidCallback onPanEnd;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => onPanStart(),
      onPointerMove: (e) => onPanUpdate(e.delta.dx, e.delta.dy),
      onPointerUp: (_) => onPanEnd(),
      onPointerCancel: (_) => onPanEnd(),
      child: Center(
        child: Container(
          width: visualSize,
          height: visualSize,
          decoration: BoxDecoration(
            color: const Color(0xFFF7F0E4),
            border: Border.all(color: const Color(0xFF5B8C5A), width: 2.5),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 5,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
