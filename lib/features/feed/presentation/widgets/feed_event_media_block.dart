import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/media/gallery_media_utils.dart';
import '../../../../core/widgets/gallery_video_player.dart';
import '../../../chat/presentation/widgets/chat_network_image.dart';

/// Медиа в ленте: высота подстраивается под пропорции фото.
///
/// - одно фото → рамка по его aspect (clamp 4:5 … ~16:9);
/// - карусель → по самому «высокому» (меньший w/h);
/// - [BoxFit.cover] — без серых полос.
class FeedEventMediaBlock extends StatefulWidget {
  const FeedEventMediaBlock({
    super.key,
    required this.photos,
    required this.onPhotoTap,
    this.initialIndex = 0,
    this.onIndexChanged,
  });

  final List<Map<String, dynamic>> photos;
  final void Function(int index) onPhotoTap;
  final int initialIndex;
  final ValueChanged<int>? onIndexChanged;

  static const double minAspect = 0.8;
  static const double maxAspect = 1.91;
  static const double fallbackAspect = 1.0;

  @override
  State<FeedEventMediaBlock> createState() => _FeedEventMediaBlockState();
}

class _FeedEventMediaBlockState extends State<FeedEventMediaBlock> {
  late final PageController _pageController;
  late int _index;
  late List<double?> _aspects;
  double _frameAspect = FeedEventMediaBlock.fallbackAspect;

  static final Map<String, double> _aspectCache = {};

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageController = PageController(initialPage: _index);
    _aspects = List<double?>.filled(widget.photos.length, null);
    _hydrateFromCache();
    _resolveAspects();
  }

  @override
  void didUpdateWidget(covariant FeedEventMediaBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePhotos(oldWidget.photos, widget.photos)) {
      _aspects = List<double?>.filled(widget.photos.length, null);
      _hydrateFromCache();
      _recomputeFrameAspect();
      _resolveAspects();
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool _samePhotos(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_photoCacheKey(a[i]) != _photoCacheKey(b[i])) return false;
    }
    return true;
  }

  String _photoCacheKey(Map<String, dynamic> photo) {
    final id = photo['id'] ?? photo['attachment_id'];
    if (id != null) return 'id:$id';
    return 'url:${galleryAttachmentUrl(photo)}';
  }

  String _photoUrl(Map<String, dynamic> photo) => galleryAttachmentUrl(photo);

  double _clampAspect(double ar) {
    if (ar <= 0 || ar.isNaN) return FeedEventMediaBlock.fallbackAspect;
    return ar.clamp(
      FeedEventMediaBlock.minAspect,
      FeedEventMediaBlock.maxAspect,
    );
  }

  void _hydrateFromCache() {
    for (var i = 0; i < widget.photos.length; i++) {
      final cached = _aspectCache[_photoCacheKey(widget.photos[i])];
      if (cached != null) _aspects[i] = cached;
    }
    _recomputeFrameAspect();
  }

  void _recomputeFrameAspect() {
    final known = _aspects.whereType<double>().toList();
    if (known.isEmpty) {
      _frameAspect = FeedEventMediaBlock.fallbackAspect;
      return;
    }
    var best = _clampAspect(known.first);
    for (final ar in known.skip(1)) {
      final c = _clampAspect(ar);
      if (c < best) best = c;
    }
    _frameAspect = best;
  }

  Future<void> _resolveAspects() async {
    final photos = List<Map<String, dynamic>>.from(widget.photos);
    for (var i = 0; i < photos.length; i++) {
      if (_aspects[i] != null) continue;
      final ar = await _resolveOne(photos[i]);
      if (!mounted) return;
      if (ar == null) continue;
      if (i >= widget.photos.length) return;
      if (_photoCacheKey(widget.photos[i]) != _photoCacheKey(photos[i])) return;
      setState(() {
        _aspects[i] = ar;
        _aspectCache[_photoCacheKey(photos[i])] = ar;
        _recomputeFrameAspect();
      });
    }
  }

  Future<double?> _resolveOne(Map<String, dynamic> photo) async {
    final key = _photoCacheKey(photo);
    final cached = _aspectCache[key];
    if (cached != null) return cached;

    final url = _photoUrl(photo);
    if (url.isEmpty) return null;
    if (isVideoAttachment(photo)) return FeedEventMediaBlock.fallbackAspect;

    final provider = NetworkImage(url);
    final completer = Completer<double?>();
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        completer.complete(w > 0 && h > 0 ? w / h : null);
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

  double _mediaHeight(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - 24;
    final maxH = MediaQuery.sizeOf(context).height * 0.72;
    const minH = 180.0;
    final h = width / _frameAspect;
    return h.clamp(minH, maxH > 560 ? 560.0 : maxH);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final height = _mediaHeight(context);
    final showCounter = widget.photos.length > 1;

    Widget buildMedia(Map<String, dynamic> photo) {
      if (isVideoAttachment(photo)) {
        return GalleryVideoPlayer(
          url: _photoUrl(photo),
          fit: BoxFit.cover,
        );
      }
      final threadId = photo['thread_id'] is int
          ? photo['thread_id'] as int
          : int.tryParse('${photo['thread_id']}');
      if (threadId != null) {
        return ChatNetworkImage(
          threadId: threadId,
          attachment: photo,
          width: double.infinity,
          height: height,
          fit: BoxFit.cover,
        );
      }
      return const Center(child: Icon(Icons.broken_image_outlined));
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: ColoredBox(
        color: cs.surfaceContainerHighest,
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.photos.length == 1)
                GestureDetector(
                  onTap: () => widget.onPhotoTap(0),
                  child: buildMedia(widget.photos.first),
                )
              else
                PageView.builder(
                  controller: _pageController,
                  itemCount: widget.photos.length,
                  onPageChanged: (value) {
                    setState(() => _index = value);
                    widget.onIndexChanged?.call(value);
                  },
                  itemBuilder: (_, index) {
                    return GestureDetector(
                      onTap: () => widget.onPhotoTap(index),
                      child: buildMedia(widget.photos[index]),
                    );
                  },
                ),
              if (showCounter)
                Positioned(
                  top: 10,
                  right: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        '${_index + 1} / ${widget.photos.length}',
                        style:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
