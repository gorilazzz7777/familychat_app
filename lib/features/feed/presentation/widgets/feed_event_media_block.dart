import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../chat/presentation/widgets/chat_network_image.dart';

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

  @override
  State<FeedEventMediaBlock> createState() => _FeedEventMediaBlockState();
}

class _FeedEventMediaBlockState extends State<FeedEventMediaBlock> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, math.max(0, widget.photos.length - 1));
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  double _mediaHeight(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - 24;
    final maxH = math.min(MediaQuery.sizeOf(context).height * 0.55, 480.0);
    const minH = 200.0;
    const aspect = 0.8;
    return (width / aspect).clamp(minH, maxH);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final height = _mediaHeight(context);
    final showCounter = widget.photos.length > 1;

    Widget buildPhoto(Map<String, dynamic> photo) {
      final threadId = photo['thread_id'] as int;
      return ChatNetworkImage(
        threadId: threadId,
        attachment: photo,
        width: double.infinity,
        height: height,
        fit: BoxFit.contain,
      );
    }

    return ColoredBox(
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
                child: Center(child: buildPhoto(widget.photos.first)),
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
                    child: Center(child: buildPhoto(widget.photos[index])),
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    child: Text(
                      '${_index + 1} / ${widget.photos.length}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
    );
  }
}
