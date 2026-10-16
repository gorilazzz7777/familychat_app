import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/widgets/family_app_bar.dart';
import '../../../../core/widgets/zoom_aware_page_view.dart';

/// Shared fullscreen page-view shell for gallery / chat photo viewers.
///
/// Translucent app bar auto-hides; tap media to show/hide chrome.
class GalleryFullscreenViewerCore extends StatefulWidget {
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
    this.chromeAutoHideAfter = const Duration(seconds: 3),
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
  final Duration chromeAutoHideAfter;

  @override
  State<GalleryFullscreenViewerCore> createState() =>
      _GalleryFullscreenViewerCoreState();
}

class _GalleryFullscreenViewerCoreState
    extends State<GalleryFullscreenViewerCore> {
  bool _chromeVisible = true;
  Timer? _hideChromeTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHideChrome();
  }

  @override
  void dispose() {
    _hideChromeTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GalleryFullscreenViewerCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title && _chromeVisible) {
      _scheduleHideChrome();
    }
  }

  void _scheduleHideChrome() {
    _hideChromeTimer?.cancel();
    _hideChromeTimer = Timer(widget.chromeAutoHideAfter, () {
      if (!mounted || !_chromeVisible) return;
      setState(() => _chromeVisible = false);
    });
  }

  void _showChrome({bool autoHide = true}) {
    _hideChromeTimer?.cancel();
    if (!_chromeVisible) {
      setState(() => _chromeVisible = true);
    }
    if (autoHide) _scheduleHideChrome();
  }

  void _toggleChrome() {
    if (_chromeVisible) {
      _hideChromeTimer?.cancel();
      setState(() => _chromeVisible = false);
    } else {
      _showChrome();
    }
  }

  void _onPageChanged(int index) {
    widget.onPageChanged(index);
    _showChrome();
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    const collapsedBottomBarHeight = 44.0;
    final bottomBarHeight =
        widget.bottomSlots.isEmpty ? 0.0 : collapsedBottomBarHeight + safeBottom;
    final stripBottom = bottomBarHeight;
    final chromeOpacity = _chromeVisible ? 1.0 : 0.0;
    final topPad = MediaQuery.paddingOf(context).top;
    final chromeBarHeight = kToolbarHeight + topPad;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.black,
      ),
      child: Scaffold(
        backgroundColor: widget.backgroundColor,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: Size.fromHeight(chromeBarHeight),
          child: AnimatedOpacity(
            opacity: chromeOpacity,
            duration: const Duration(milliseconds: 180),
            child: IgnorePointer(
              ignoring: !_chromeVisible,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.78),
                      Colors.black.withValues(alpha: 0.52),
                    ],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: FamilyAppBar.build(
                    title: widget.title,
                    backgroundColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    iconTheme: const IconThemeData(color: Colors.white),
                    forceMaterialTransparency: true,
                    actions: widget.actions,
                  ),
                ),
              ),
            ),
          ),
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleChrome,
                child: widget.zoomPageKey != null
                    ? ZoomAwarePageView(
                        key: widget.zoomPageKey,
                        controller: widget.pageController,
                        itemCount: widget.itemCount,
                        onPageChanged: _onPageChanged,
                        itemBuilder: widget.pageBuilder,
                      )
                    : PageView.builder(
                        controller: widget.pageController,
                        itemCount: widget.itemCount,
                        onPageChanged: _onPageChanged,
                        itemBuilder: widget.pageBuilder,
                      ),
              ),
            ),
            if (widget.thumbnailStrip != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: stripBottom,
                child: AnimatedOpacity(
                  opacity: chromeOpacity,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: widget.thumbnailStrip!,
                  ),
                ),
              ),
            if (widget.bottomSlots.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: chromeOpacity,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: widget.bottomSlots,
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
