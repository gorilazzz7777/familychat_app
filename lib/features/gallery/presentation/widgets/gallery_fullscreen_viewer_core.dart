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
    this.thumbnailStrip,
    this.bottomSlots = const [],
    this.backgroundColor = Colors.black,
  });

  final PageController pageController;
  final int itemCount;
  final ValueChanged<int> onPageChanged;
  final NullableIndexedWidgetBuilder pageBuilder;
  final GlobalKey<ZoomAwarePageViewState>? zoomPageKey;
  final String title;
  final List<Widget> actions;
  final Widget? thumbnailStrip;
  final List<Widget> bottomSlots;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    const collapsedBottomBarHeight = 44.0;
    final bottomBarHeight =
        bottomSlots.isEmpty ? 0.0 : collapsedBottomBarHeight + safeBottom;
    final stripBottom = bottomBarHeight;

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: FamilyAppBar.build(
        title: title,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: actions,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
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
          if (thumbnailStrip != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: stripBottom,
              child: thumbnailStrip!,
            ),
          if (bottomSlots.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: bottomSlots,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
