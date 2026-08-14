import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Мозаика как в Google Photos: 3 в ряд, крупная 2×2 + мелкие, огромная 3×3.
///
/// Крупные плитки всегда идут первыми в блоке (укладка слева направо),
/// иначе `QuiltedGridTile(2,2)` может стартовать с колонки 2 → RangeError.
abstract final class GalleryMosaicLayout {
  static const crossAxisCount = 3;
  static const spacing = 4.0;
  static const padding = 8.0;

  static const pattern = <QuiltedGridTile>[
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(2, 2),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(3, 3),
    QuiltedGridTile(2, 2),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
    QuiltedGridTile(1, 1),
  ];

  static SliverQuiltedGridDelegate delegate() {
    return SliverQuiltedGridDelegate(
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      repeatPattern: QuiltedGridRepeatPattern.same,
      pattern: pattern,
    );
  }
}
