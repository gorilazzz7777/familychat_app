import 'dart:async';

import 'package:flutter/material.dart';

/// Показывает [child] только если виджет прожил дольше [delay].
/// Если данные пришли быстрее — заглушка не мелькает.
class DeferredPlaceholder extends StatefulWidget {
  const DeferredPlaceholder({
    super.key,
    required this.child,
    this.delay = const Duration(seconds: 1),
  });

  final Widget child;
  final Duration delay;

  @override
  State<DeferredPlaceholder> createState() => _DeferredPlaceholderState();
}

class _DeferredPlaceholderState extends State<DeferredPlaceholder> {
  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Пусто до delay: при быстрой загрузке заглушка не мигает.
    // В Expanded/tight-constraints shrink всё равно займёт доступную область.
    if (!_visible) return const SizedBox.shrink();
    return widget.child;
  }
}

/// Лёгкие плейсхолдеры для первой отрисовки, пока грузятся данные.
class AppSkeletonBox extends StatelessWidget {
  const AppSkeletonBox({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = 8,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
    if (width != null) return box;
    return SizedBox(width: double.infinity, child: box);
  }
}

class ChatHubListSkeleton extends StatelessWidget {
  const ChatHubListSkeleton({super.key, this.itemCount = 8});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: itemCount,
      itemBuilder: (context, _) => const _ChatHubTileSkeleton(),
    );
  }
}

class _ChatHubTileSkeleton extends StatelessWidget {
  const _ChatHubTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          AppSkeletonBox(width: 48, height: 48, borderRadius: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSkeletonBox(width: 140, height: 14),
                SizedBox(height: 8),
                AppSkeletonBox(height: 12),
              ],
            ),
          ),
          SizedBox(width: 12),
          AppSkeletonBox(width: 40, height: 10),
        ],
      ),
    );
  }
}

class FeedListSkeleton extends StatelessWidget {
  const FeedListSkeleton({super.key, this.itemCount = 4});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: itemCount,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, _) => const _FeedCardSkeleton(),
    );
  }
}

class _FeedCardSkeleton extends StatelessWidget {
  const _FeedCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppSkeletonBox(width: 36, height: 36, borderRadius: 18),
              SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppSkeletonBox(width: 120, height: 12),
                    SizedBox(height: 6),
                    AppSkeletonBox(width: 80, height: 10),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          AppSkeletonBox(height: 12),
          SizedBox(height: 8),
          AppSkeletonBox(width: 220, height: 12),
          SizedBox(height: 12),
          AppSkeletonBox(height: 160, borderRadius: 12),
        ],
      ),
    );
  }
}

class ChatMessagesSkeleton extends StatelessWidget {
  const ChatMessagesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        _BubbleSkeleton(alignEnd: false, width: 180),
        SizedBox(height: 10),
        _BubbleSkeleton(alignEnd: true, width: 140),
        SizedBox(height: 10),
        _BubbleSkeleton(alignEnd: false, width: 220),
        SizedBox(height: 10),
        _BubbleSkeleton(alignEnd: true, width: 160),
        SizedBox(height: 10),
        _BubbleSkeleton(alignEnd: false, width: 120),
        SizedBox(height: 10),
        _BubbleSkeleton(alignEnd: true, width: 200),
      ],
    );
  }
}

class _BubbleSkeleton extends StatelessWidget {
  const _BubbleSkeleton({required this.alignEnd, required this.width});

  final bool alignEnd;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: AppSkeletonBox(
        width: width,
        height: 42,
        borderRadius: 16,
      ),
    );
  }
}
