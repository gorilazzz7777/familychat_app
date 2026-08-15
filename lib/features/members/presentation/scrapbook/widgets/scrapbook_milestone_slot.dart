import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';

import '../../../../../core/media/gallery_media_utils.dart';
import '../utils/scrapbook_media_layout_store.dart';
import '../utils/scrapbook_media_prefetch.dart';
import '../utils/scrapbook_milestone_info.dart';
import '../utils/scrapbook_milestone_media.dart';
import 'scrapbook_kraft_background.dart';

class ScrapbookLayoutEditRequest {
  const ScrapbookLayoutEditRequest({
    required this.milestoneCode,
    required this.milestoneTitle,
    required this.media,
    required this.aspects,
    required this.layouts,
    this.initialSelectedIndex = 0,
    this.dateLabel,
    this.note,
    this.weightLabel,
    this.heightLabel,
    this.ageLabel,
  });

  final String milestoneCode;
  final String milestoneTitle;
  final List<Map<String, dynamic>> media;
  final List<double> aspects;
  final Map<String, ScrapbookMediaRect> layouts;
  final int initialSelectedIndex;
  final String? dateLabel;
  final String? note;
  final String? weightLabel;
  final String? heightLabel;
  final String? ageLabel;
}

/// Одностраничная карточка вехи: медиа в рамке + комментарий на строчках.
class ScrapbookMilestoneSlot extends StatelessWidget {
  const ScrapbookMilestoneSlot({
    super.key,
    required this.milestone,
    required this.achieved,
    this.birthDate,
    this.onTapMedia,
    this.onTapPlaceholder,
    this.onRequestLayoutEdit,
    this.layoutRevision = 0,
  });

  final Map<String, dynamic> milestone;
  final bool achieved;
  final DateTime? birthDate;
  final void Function(List<Map<String, dynamic>> media, {int initialIndex})?
      onTapMedia;
  final VoidCallback? onTapPlaceholder;
  final void Function(ScrapbookLayoutEditRequest request)? onRequestLayoutEdit;
  final int layoutRevision;

  String get _title => milestone['title']?.toString().trim() ?? 'Веха';

  String? get _note {
    final raw = milestone['note']?.toString().trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  String? get _achievedDateLabel =>
      scrapbookMilestoneAchievedDateLabel(milestone);

  String? get _ageLabel => scrapbookMilestoneAgeLabel(
        milestone: milestone,
        birthDate: birthDate,
      );

  List<Map<String, dynamic>> get _media => scrapbookMilestoneMedia(milestone);

  String? get _weightLabel {
    final raw = milestone['weight_kg'];
    if (raw == null) return null;
    final n = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (n == null) return null;
    final text = n == n.roundToDouble() ? '${n.toInt()}' : n.toStringAsFixed(1);
    return '$text кг';
  }

  String? get _heightLabel {
    final raw = milestone['height_cm'];
    if (raw == null) return null;
    final n = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (n == null) return null;
    final text = n == n.roundToDouble() ? '${n.toInt()}' : n.toStringAsFixed(1);
    return '$text см';
  }

  int get _mediaAreaFlex {
    final n = _media.length;
    if (!_hasNote) return 1;
    if (n <= 1) return 5;
    if (n <= 3) return 6;
    return 7;
  }

  int get _commentAreaFlex {
    final n = _media.length;
    if (n <= 1) return 3;
    if (n <= 3) return 3;
    return 2;
  }

  bool get _hasNote => _note != null && _note!.isNotEmpty;

  bool get _hasMeta =>
      _weightLabel != null || _heightLabel != null || _ageLabel != null;

  @override
  Widget build(BuildContext context) {
    if (!achieved) {
      return _AheadCard(title: _title, onTap: onTapPlaceholder);
    }

    final code = milestone['code']?.toString() ?? '';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTapPlaceholder,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _title,
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
              if (_achievedDateLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  _achievedDateLabel!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.caveat(
                    fontSize: 17,
                    color: const Color(0xFF7A5C44),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                flex: _mediaAreaFlex,
                child: _media.isEmpty
                    ? _EmptyMedia(onTap: onTapPlaceholder)
                    : _MediaGrid(
                        key: ValueKey(code),
                        milestoneCode: code,
                        milestoneTitle: _title,
                        dateLabel: _achievedDateLabel,
                        note: _note,
                        weightLabel: _weightLabel,
                        heightLabel: _heightLabel,
                        ageLabel: _ageLabel,
                        media: _media,
                        layoutRevision: layoutRevision,
                        onTap: (index) =>
                            onTapMedia?.call(_media, initialIndex: index),
                        onRequestLayoutEdit: onRequestLayoutEdit,
                      ),
              ),
              if (_hasNote) ...[
                const SizedBox(height: 12),
                Expanded(
                  flex: _commentAreaFlex,
                  child: _CommentLines(
                    note: _note,
                    ageLabel: _ageLabel,
                    weightLabel: _weightLabel,
                    heightLabel: _heightLabel,
                  ),
                ),
              ] else if (_hasMeta) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    if (_weightLabel != null)
                      _MetaLine(label: 'Мой вес', value: _weightLabel!),
                    if (_heightLabel != null)
                      _MetaLine(label: 'Мой рост', value: _heightLabel!),
                    if (_ageLabel != null)
                      _MetaLine(label: 'Мой возраст', value: _ageLabel!),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMedia extends StatelessWidget {
  const _EmptyMedia({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: const _AgedRectPainter(),
        child: Center(
          child: Text(
            'Добавить фото',
            style: GoogleFonts.caveat(
              fontSize: 20,
              color: const Color(0xFF8B7355),
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaGrid extends StatefulWidget {
  const _MediaGrid({
    super.key,
    required this.milestoneCode,
    required this.milestoneTitle,
    required this.media,
    required this.onTap,
    this.dateLabel,
    this.note,
    this.weightLabel,
    this.heightLabel,
    this.ageLabel,
    this.layoutRevision = 0,
    this.onRequestLayoutEdit,
  });

  final String milestoneCode;
  final String milestoneTitle;
  final String? dateLabel;
  final String? note;
  final String? weightLabel;
  final String? heightLabel;
  final String? ageLabel;
  final List<Map<String, dynamic>> media;
  final int layoutRevision;
  final void Function(int index) onTap;
  final void Function(ScrapbookLayoutEditRequest request)? onRequestLayoutEdit;

  @override
  State<_MediaGrid> createState() => _MediaGridState();
}

class _MediaGridState extends State<_MediaGrid> {
  late List<double?> _aspects;
  Map<String, ScrapbookMediaRect> _layouts = {};
  bool _layoutsReady = false;
  bool _defaultsPersisted = false;
  Size? _lastSize;

  @override
  void initState() {
    super.initState();
    _aspects = List<double?>.filled(_visibleCount, null);
    _seedFromCache();
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant _MediaGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameMedia(oldWidget.media, widget.media) ||
        oldWidget.milestoneCode != widget.milestoneCode) {
      _aspects = List<double?>.filled(_visibleCount, null);
      _layouts = {};
      _layoutsReady = false;
      _defaultsPersisted = false;
      _seedFromCache();
      _bootstrap();
      return;
    }
    if (oldWidget.layoutRevision != widget.layoutRevision) {
      final cached = ScrapbookMediaLayoutStore.peek(widget.milestoneCode);
      if (cached != null) {
        setState(() {
          _layouts = scrapbookAlignLayoutsToMedia(
            layouts: cached,
            media: widget.media.take(6).toList(),
          );
          _layoutsReady = true;
        });
      } else {
        _bootstrap();
      }
    }
  }

  int get _visibleCount => widget.media.length.clamp(0, 6);

  bool _sameMedia(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length && i < 6; i++) {
      if (galleryAttachmentUrl(a[i]) != galleryAttachmentUrl(b[i])) {
        return false;
      }
    }
    return true;
  }

  void _seedFromCache() {
    final code = widget.milestoneCode;
    final cached = ScrapbookMediaLayoutStore.peek(code);
    if (cached != null) {
      _layouts = scrapbookAlignLayoutsToMedia(
        layouts: cached,
        media: widget.media.take(6).toList(),
      );
      _layoutsReady = true;
    }
    for (var i = 0; i < _visibleCount; i++) {
      final key = scrapbookMediaLayoutKey(widget.media[i]);
      final fromLayout = scrapbookLookupLayout(_layouts, widget.media[i])?.aspect;
      final fromCache = ScrapbookMediaLayoutStore.peekAspect(key);
      _aspects[i] = fromLayout ?? fromCache;
    }
  }

  Future<void> _bootstrap() async {
    final code = widget.milestoneCode;
    final saved = code.isEmpty
        ? <String, ScrapbookMediaRect>{}
        : await ScrapbookMediaLayoutStore.load(code);
    if (!mounted) return;

    final aligned = scrapbookAlignLayoutsToMedia(
      layouts: saved,
      media: widget.media.take(6).toList(),
    );

    setState(() {
      _layouts = aligned;
      _layoutsReady = true;
      for (var i = 0; i < _visibleCount; i++) {
        final key = scrapbookMediaLayoutKey(widget.media[i]);
        _aspects[i] ??= scrapbookLookupLayout(aligned, widget.media[i])?.aspect ??
            ScrapbookMediaLayoutStore.peekAspect(key);
      }
    });

    await _resolveAspects();
    if (!mounted) return;
    _stabilizeAndPersist();
  }

  Future<void> _resolveAspects() async {
    final n = _visibleCount;
    final futures = <Future<void>>[];
    for (var i = 0; i < n; i++) {
      if (_aspects[i] != null) continue;
      final index = i;
      futures.add(() async {
        final ar = await resolveMediaAspectRatio(widget.media[index]);
        if (!mounted) return;
        final value = ar ?? 1.0;
        final key = scrapbookMediaLayoutKey(widget.media[index]);
        ScrapbookMediaLayoutStore.putAspect(key, value);
        // Fire-and-forget persist
        ScrapbookMediaLayoutStore.persistAspect(key, value);
        if (index < _aspects.length) {
          setState(() => _aspects[index] = value);
        }
      }());
    }
    if (futures.isNotEmpty) await Future.wait(futures);
  }

  List<double> get _resolvedAspects {
    return List<double>.generate(
      _visibleCount,
      (i) => _aspects[i] ??
          scrapbookLookupLayout(_layouts, widget.media[i])?.aspect ??
          1.0,
    );
  }

  String _key(int index) => scrapbookMediaLayoutKey(widget.media[index]);

  double _aspectOf(int index) =>
      _aspects[index] ??
      scrapbookLookupLayout(_layouts, widget.media[index])?.aspect ??
      1.0;

  /// Рамки без поворота должны совпадать с aspect фото (±15%).
  bool _layoutsMatchPhotoAspects(
    List<Map<String, dynamic>> media,
    int n,
  ) {
    final area = _lastSize;
    if (area == null || area.width <= 0 || area.height <= 0) return true;

    for (var i = 0; i < n; i++) {
      final layout = scrapbookLookupLayout(_layouts, media[i]);
      if (layout == null) return false;
      if (layout.rotationDeg.abs() > 0.5) return true; // ручная правка
      final ar = _aspectOf(i);
      if (ar <= 0) continue;
      final h = layout.height;
      final w = layout.width;
      if (h == null || h <= 0 || w <= 0) return false;
      // v2: width/height — доли одной оси → frameAr = w/h.
      // v1: height — доля высоты контейнера.
      final frameAr = layout.spaceVersion >= 2
          ? w / h
          : (w / h) * (area.width / area.height);
      final rel = (frameAr - ar).abs() / ar;
      if (rel > 0.15) return false;
    }
    return true;
  }

  /// True when every visible item can be drawn at its final size (no jump).
  bool get _canPaintStable {
    if (!_layoutsReady) return false;
    final area = _lastSize;
    if (area == null || area.width <= 0 || area.height <= 0) return false;

    for (var i = 0; i < _visibleCount; i++) {
      final layout = scrapbookLookupLayout(_layouts, widget.media[i]);
      if (layout == null) return false;
      if (layout.height != null && layout.height! > 0) continue;
      if (layout.aspect != null && layout.aspect! > 0) continue;
      if (_aspects[i] == null) return false;
    }
    return true;
  }

  void _stabilizeAndPersist() {
    final area = _lastSize;
    if (area == null || area.width <= 0 || area.height <= 0) return;
    if (!_layoutsReady) return;

    var changed = false;
    final n = _visibleCount;
    final media = widget.media.take(6).toList();

    // Fill missing layouts once all aspects are known.
    // Также пересобираем коллаж, если сохранённые рамки не совпадают с
    // пропорциями фото (типичный баг «поля» внутри рамки) и нет поворотов.
    if (_aspects.take(n).every((a) => a != null)) {
      final defaults = ScrapbookMediaLayoutStore.defaultLayouts(
        media: media,
        aspects: _resolvedAspects,
        containerW: area.width,
        containerH: area.height,
      );
      final missing = <int>[];
      for (var i = 0; i < n; i++) {
        if (scrapbookLookupLayout(_layouts, media[i]) == null) {
          missing.add(i);
        }
      }
      final needsCollageRebuild = (n == 3 || n == 4) &&
          missing.isEmpty &&
          !_layoutsMatchPhotoAspects(media, n);

      if (needsCollageRebuild) {
        _layouts = Map<String, ScrapbookMediaRect>.from(defaults);
        changed = true;
      } else {
        for (final i in missing) {
          final key = _key(i);
          final def = defaults[key];
          if (def == null) continue;
          _layouts[key] = def;
          changed = true;
        }
      }
    }

    // Upgrade legacy layouts (v1 / no height) → width-space v2,
    // и подогнать height под реальный aspect фото.
    for (var i = 0; i < n; i++) {
      final key = _key(i);
      final layout = scrapbookLookupLayout(_layouts, media[i]);
      if (layout == null) continue;
      if (_aspects[i] == null && layout.aspect == null) continue;
      final ar = _aspectOf(i);
      var next = layout;
      final needsUpgrade = layout.spaceVersion < 2 ||
          layout.height == null ||
          layout.height! <= 0 ||
          layout.aspect == null;
      if (needsUpgrade) {
        next = layout.toWidthSpace(
          containerW: area.width,
          containerH: area.height,
          aspect: ar,
        );
      }
      // v2: height — доля ширины; для фото height = width / aspect.
      if (ar > 0 && next.spaceVersion >= 2) {
        final expectedH = next.width / ar;
        final h = next.height;
        if (h == null || h <= 0 || (h - expectedH).abs() > 0.015) {
          next = next.copyWith(height: expectedH, aspect: ar);
        } else if (next.aspect == null) {
          next = next.copyWith(aspect: ar);
        }
      }
      if (!identical(next, layout) &&
          (next.height != layout.height ||
              next.aspect != layout.aspect ||
              next.spaceVersion != layout.spaceVersion ||
              next.top != layout.top ||
              next.left != layout.left ||
              next.width != layout.width)) {
        _layouts[key] = next;
        changed = true;
      }
    }

    if (!changed) return;
    setState(() {});
    if (widget.milestoneCode.isNotEmpty) {
      ScrapbookMediaLayoutStore.save(widget.milestoneCode, _layouts);
      _defaultsPersisted = true;
    }
  }

  void _openEditor(int index) {
    final cb = widget.onRequestLayoutEdit;
    if (cb == null || widget.milestoneCode.isEmpty) return;
    final area = _lastSize;
    if (area != null) _stabilizeAndPersist();
    cb(
      ScrapbookLayoutEditRequest(
        milestoneCode: widget.milestoneCode,
        milestoneTitle: widget.milestoneTitle,
        media: widget.media.take(6).toList(),
        aspects: _resolvedAspects,
        layouts: Map<String, ScrapbookMediaRect>.from(_layouts),
        initialSelectedIndex: index,
        dateLabel: widget.dateLabel,
        note: widget.note,
        weightLabel: widget.weightLabel,
        heightLabel: widget.heightLabel,
        ageLabel: widget.ageLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.media.length;
    final n = _visibleCount;
    if (n == 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        final sizeChanged = _lastSize != area;
        _lastSize = area;
        if (sizeChanged || !_defaultsPersisted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _stabilizeAndPersist();
          });
        }

        if (!_canPaintStable) {
          // Empty slot — no temporary wrong positions (avoids jump).
          return const SizedBox.expand();
        }

        final rawRects = <RectPx>[];
        for (var i = 0; i < n; i++) {
          final layout = scrapbookLookupLayout(_layouts, widget.media[i]);
          if (layout == null) {
            rawRects.add(const RectPx(left: 0, top: 0, width: 0, height: 0));
            continue;
          }
          rawRects.add(
            layout.toPixels(
              aspect: _aspectOf(i),
              containerW: area.width,
              containerH: area.height,
            ),
          );
        }
        final fitted = fitRectsIntoArea(rawRects, area);

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (var i = 0; i < n; i++)
              _positionedItem(i, fitted[i], total),
          ],
        );
      },
    );
  }

  Widget _positionedItem(int index, RectPx px, int totalCount) {
    if (px.width <= 0 || px.height <= 0) {
      return const SizedBox.shrink();
    }

    final layout = scrapbookLookupLayout(_layouts, widget.media[index]);
    final overflow = totalCount > 6 && index == 5;
    final rotDeg = layout?.rotationDeg ?? 0;

    return Positioned(
      left: px.left,
      top: px.top,
      width: px.width,
      height: px.height,
      child: Transform.rotate(
        angle: rotDeg * math.pi / 180,
        child: GestureDetector(
          onTap: () => widget.onTap(index),
          onLongPress: () => _openEditor(index),
          child: AgedMediaFrame(
            attachment: widget.media[index],
            badge: overflow ? '+${totalCount - 5}' : null,
          ),
        ),
      ),
    );
  }
}

Future<double?> resolveMediaAspectRatio(Map<String, dynamic> attachment) async {
  final key = scrapbookMediaLayoutKey(attachment);
  final cached = ScrapbookMediaLayoutStore.peekAspect(key);
  if (cached != null) return cached;

  final url = galleryAttachmentUrl(attachment);
  if (url.isEmpty) return null;

  if (isVideoAttachment(attachment)) {
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
      final size = controller.value.size;
      if (size.width <= 0 || size.height <= 0) return null;
      final ar = size.width / size.height;
      ScrapbookMediaLayoutStore.putAspect(key, ar);
      return ar;
    } catch (_) {
      return null;
    } finally {
      await controller.dispose();
    }
  }

  final provider = NetworkImage(url);
  final completer = Completer<double?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      final ar = w > 0 && h > 0 ? w / h : null;
      if (ar != null) ScrapbookMediaLayoutStore.putAspect(key, ar);
      completer.complete(ar);
      stream.removeListener(listener);
    },
    onError: (Object _, StackTrace? __) {
      completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () => null,
  );
}

class _CommentLines extends StatelessWidget {
  const _CommentLines({
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
                _MetaLine(label: 'Мой вес', value: weightLabel!),
              if (heightLabel != null)
                _MetaLine(label: 'Мой рост', value: heightLabel!),
              if (ageLabel != null)
                _MetaLine(label: 'Мой возраст', value: ageLabel!),
            ],
          ),
        ],
      ],
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$label: $value',
      style: GoogleFonts.caveat(
        fontSize: 16,
        color: const Color(0xFF4A3728),
      ),
    );
  }
}

class _AheadCard extends StatelessWidget {
  const _AheadCard({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.merriweather(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF4A3728),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Скоро здесь появится ваша история',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.caveat(
                    fontSize: 18,
                    color: const Color(0xFF8B7355),
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

/// Фото/видео в ветхой рамке.
class AgedMediaFrame extends StatelessWidget {
  const AgedMediaFrame({
    super.key,
    required this.attachment,
    this.onTap,
    this.badge,
  });

  final Map<String, dynamic> attachment;
  final VoidCallback? onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final isVideo = isVideoAttachment(attachment);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: CustomPaint(
          painter: const _AgedRectPainter(),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (isVideo)
                  _VideoPreview(
                    url: galleryAttachmentUrl(attachment),
                    fit: BoxFit.contain,
                  )
                else
                  ScrapbookCachedPhoto(
                    url: galleryAttachmentUrl(attachment),
                    fit: BoxFit.contain,
                  ),
                if (isVideo)
                  const Center(
                    child: Icon(
                      Icons.play_circle_fill,
                      color: Colors.white,
                      size: 36,
                      shadows: [
                        Shadow(color: Colors.black54, blurRadius: 6),
                      ],
                    ),
                  ),
                if (badge != null)
                  ColoredBox(
                    color: Colors.black45,
                    child: Center(
                      child: Text(
                        badge!,
                        style: GoogleFonts.merriweather(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
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

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({
    required this.url,
    this.fit = BoxFit.contain,
  });

  final String url;
  final BoxFit fit;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _VideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _controller?.dispose();
      _controller = null;
      _init();
    }
  }

  Future<void> _init() async {
    final url = widget.url.trim();
    if (url.isEmpty) return;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;
    try {
      await controller.initialize();
      await controller.pause();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Color(0xFF2A2118));
    }
    return FittedBox(
      fit: widget.fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: controller.value.size.width,
        height: controller.value.size.height,
        child: VideoPlayer(controller),
      ),
    );
  }
}

class _AgedRectPainter extends CustomPainter {
  const _AgedRectPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(2, 2, size.width - 4, size.height - 4);

    final fill = Paint()..color = const Color(0xFFF7F0E4);
    canvas.drawRect(rect, fill);

    final border = Paint()
      ..color = const Color(0xFF8B7355)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawRect(rect, border);

    final outer = Paint()
      ..color = const Color(0x668B7355)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    canvas.drawRect(rect.inflate(2.5), outer);

    final wash = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0x33A67B5B),
          Colors.transparent,
          const Color(0x228B7355),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, wash);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
