import 'package:flutter/material.dart';

import '../../../../../core/media/gallery_media_utils.dart';
import '../../../../../core/widgets/family_public_image.dart';
import '../../../../../core/widgets/gallery_video_player.dart';
import '../../../../gallery/presentation/gallery_media_thumbnail.dart';

class ScrapbookMilestoneMediaViewer extends StatefulWidget {
  const ScrapbookMilestoneMediaViewer({
    super.key,
    required this.title,
    required this.media,
    this.initialIndex = 0,
  });

  final String title;
  final List<Map<String, dynamic>> media;
  final int initialIndex;

  static Future<void> open(
    BuildContext context, {
    required String title,
    required List<Map<String, dynamic>> media,
    int initialIndex = 0,
  }) {
    if (media.isEmpty) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ScrapbookMilestoneMediaViewer(
          title: title,
          media: media,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  @override
  State<ScrapbookMilestoneMediaViewer> createState() =>
      _ScrapbookMilestoneMediaViewerState();
}

class _ScrapbookMilestoneMediaViewerState
    extends State<ScrapbookMilestoneMediaViewer> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.media.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildPage(Map<String, dynamic> attachment, {required bool autoplay}) {
    final url = galleryAttachmentUrl(attachment);
    final local = galleryLocalDevicePath(attachment);
    if (isVideoAttachment(attachment)) {
      return GalleryVideoPlayer(
        url: url,
        localPath: local.isEmpty ? null : local,
        fit: BoxFit.contain,
        autoplay: autoplay,
      );
    }
    return InteractiveViewer(
      minScale: 0.8,
      maxScale: 5,
      child: FamilyPublicImage(
        url: url,
        localPath: local.isEmpty ? null : local,
        attachment: attachment,
        fit: BoxFit.contain,
        placeholder: const Center(child: CircularProgressIndicator()),
        error: const Center(
          child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '${_index + 1} / ${widget.media.length}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.media.length,
              onPageChanged: (value) => setState(() => _index = value),
              itemBuilder: (context, index) {
                final attachment = widget.media[index];
                return Center(
                  child: _buildPage(
                    attachment,
                    autoplay: index == _index,
                  ),
                );
              },
            ),
          ),
          if (widget.media.length > 1)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: widget.media.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final attachment = widget.media[index];
                      final selected = index == _index;
                      return GestureDetector(
                        onTap: () {
                          _controller.animateToPage(
                            index,
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                          );
                        },
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : Colors.white24,
                              width: selected ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  GalleryMediaThumbnail(
                                    attachment: attachment,
                                    fit: BoxFit.cover,
                                  ),
                                  if (isVideoAttachment(attachment))
                                    Container(
                                      color: Colors.black38,
                                      child: const Icon(
                                        Icons.play_arrow_rounded,
                                        color: Colors.white,
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
          else if (isVideoAttachment(widget.media[_index]))
            const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Видео',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
