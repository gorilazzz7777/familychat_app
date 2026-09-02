import 'package:flutter/material.dart';

import '../gallery_media_thumbnail.dart';

/// Горизонтальная лента мини-превью для карусели (лента, полноэкранный просмотр).
class GalleryCarouselThumbnailStrip extends StatefulWidget {
  const GalleryCarouselThumbnailStrip({
    super.key,
    required this.photos,
    required this.index,
    required this.onSelect,
    this.visible = true,
    this.onInteractionHeld,
    this.itemSize = 48,
    this.gap = 6,
    this.padding = const EdgeInsets.fromLTRB(8, 22, 8, 8),
  });

  final List<Map<String, dynamic>> photos;
  final int index;
  final ValueChanged<int> onSelect;
  final bool visible;
  final ValueChanged<bool>? onInteractionHeld;
  final double itemSize;
  final double gap;
  final EdgeInsets padding;

  @override
  State<GalleryCarouselThumbnailStrip> createState() =>
      _GalleryCarouselThumbnailStripState();
}

class _GalleryCarouselThumbnailStripState
    extends State<GalleryCarouselThumbnailStrip> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureItemVisible(widget.index);
    });
  }

  @override
  void didUpdateWidget(covariant GalleryCarouselThumbnailStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureItemVisible(widget.index);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _ensureItemVisible(int index) {
    if (!_controller.hasClients) return;
    final extent = widget.itemSize + widget.gap;
    final viewport = _controller.position.viewportDimension;
    final target = index * extent - (viewport - widget.itemSize) / 2;
    _controller.animateTo(
      target.clamp(0.0, _controller.position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  int? _threadId(Map<String, dynamic> photo) {
    final raw = photo['thread_id'];
    if (raw is int) return raw;
    return int.tryParse('$raw');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.length < 2) return const SizedBox.shrink();

    final child = DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0x99000000),
          ],
        ),
      ),
      child: Padding(
        padding: widget.padding,
        child: SizedBox(
          height: widget.itemSize,
          child: ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.photos.length,
            separatorBuilder: (_, __) => SizedBox(width: widget.gap),
            itemBuilder: (context, i) {
              final selected = i == widget.index;
              return GestureDetector(
                onTap: () => widget.onSelect(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: widget.itemSize,
                  height: widget.itemSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? Colors.white : Colors.white24,
                      width: selected ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: GalleryMediaThumbnail(
                    attachment: widget.photos[i],
                    threadId: _threadId(widget.photos[i]),
                    width: widget.itemSize,
                    height: widget.itemSize,
                    fit: BoxFit.cover,
                    lazyPreview: false,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    if (widget.onInteractionHeld == null) {
      return child;
    }

    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: Listener(
          onPointerDown: (_) => widget.onInteractionHeld!(true),
          onPointerUp: (_) => widget.onInteractionHeld!(false),
          onPointerCancel: (_) => widget.onInteractionHeld!(false),
          child: child,
        ),
      ),
    );
  }
}
