import 'package:flutter/material.dart';

import '../../../../core/widgets/family_app_bar.dart';
import '../../../../core/widgets/zoom_aware_page_view.dart';

/// Shared fullscreen page-view shell for gallery / chat photo viewers.
class GalleryFullscreenViewerCore extends StatelessWidget {
  const GalleryFullscreenViewerCore({
    super.key,
    required this.pageController,
    required this.itemCount,
    required this.onPageChanged,
    required this.pageBuilder,
    required this.title,
    this.zoomPageKey,
    this.actions = const [],
    this.bottomSlots = const [],
    this.pageFlex = 1,
    this.backgroundColor = Colors.black,
  });

  final PageController pageController;
  final int itemCount;
  final ValueChanged<int> onPageChanged;
  final NullableIndexedWidgetBuilder pageBuilder;
  final GlobalKey<ZoomAwarePageViewState>? zoomPageKey;
  final String title;
  final List<Widget> actions;
  final List<Widget> bottomSlots;
  final int pageFlex;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: FamilyAppBar.build(
        title: title,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: actions,
      ),
      body: Column(
        children: [
          Expanded(
            flex: pageFlex,
            child: zoomPageKey != null
                ? ZoomAwarePageView(
                    key: zoomPageKey,
                    controller: pageController,
                    itemCount: itemCount,
                    onPageChanged: onPageChanged,
                    itemBuilder: pageBuilder,
                  )
                : PageView.builder(
                    controller: pageController,
                    itemCount: itemCount,
                    onPageChanged: onPageChanged,
                    itemBuilder: pageBuilder,
                  ),
          ),
          ...bottomSlots,
        ],
      ),
    );
  }
}
