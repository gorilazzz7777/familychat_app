import 'package:flutter/material.dart';

import '../../../../core/media/gallery_photo_date.dart';
import 'gallery_date_scrubber.dart';
import 'gallery_mosaic_layout.dart';

/// Shared mosaic grid + date scrubber used by profile and child album screens.
class GalleryAlbumMosaicBody extends StatelessWidget {
  const GalleryAlbumMosaicBody({
    super.key,
    required this.scrollController,
    required this.daySections,
    required this.photoCount,
    required this.tileBuilder,
    required this.onNearEnd,
    this.loadingMore = false,
    this.loadMoreThreshold = 400,
  });

  final ScrollController scrollController;
  final List<GalleryAlbumDaySection> daySections;
  final int photoCount;
  final IndexedWidgetBuilder tileBuilder;
  final VoidCallback onNearEnd;
  final bool loadingMore;
  final double loadMoreThreshold;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >
                n.metrics.maxScrollExtent - loadMoreThreshold) {
              onNearEnd();
            }
            return false;
          },
          child: CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(GalleryMosaicLayout.padding),
                sliver: SliverGrid(
                  gridDelegate: GalleryMosaicLayout.delegate(),
                  delegate: SliverChildBuilderDelegate(
                    tileBuilder,
                    childCount: photoCount,
                  ),
                ),
              ),
              if (loadingMore)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ],
          ),
        ),
        if (daySections.isNotEmpty)
          GalleryDateScrubber(
            sections: daySections,
            scrollController: scrollController,
          ),
      ],
    );
  }
}
