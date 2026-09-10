import 'package:photo_manager/photo_manager.dart';

import 'gallery_media_export.dart';

/// Лёгкий отпечаток ассета галереи телефона (без чтения байтов).
///
/// На iOS копия в альбоме FamilyChat получает другой `asset.id`, но обычно
/// сохраняет дату съёмки / размер кадра / title — по ним можно узнать оригинал
/// в «Недавние».
String? galleryAssetFingerprint(AssetEntity asset) {
  final createdMs = asset.createDateTime.millisecondsSinceEpoch;
  if (createdMs <= 0 && asset.width <= 0 && asset.height <= 0) return null;
  final title = GalleryMediaExport.normalizeAlbumBasename(asset.title ?? '');
  final durationMs = asset.duration;
  return '${createdMs}_${asset.width}x${asset.height}_${durationMs}_$title';
}

/// Имя файла достаточно уникальное для мягкого матча (камера / таймстемп).
bool galleryFilenameLooksDistinctive(String filename) {
  final n = GalleryMediaExport.normalizeAlbumBasename(filename);
  if (n.isEmpty) return false;
  if (RegExp(r'^img[_\-]?\d+', caseSensitive: false).hasMatch(n)) return true;
  if (RegExp(r'^dsc[_\-]?\d+', caseSensitive: false).hasMatch(n)) return true;
  if (RegExp(r'^\d{8}[_\-]?\d{4,}', caseSensitive: false).hasMatch(n)) {
    return true;
  }
  if (RegExp(r'^photo_\d+', caseSensitive: false).hasMatch(n)) return true;
  return false;
}

class GalleryKnownMediaHints {
  const GalleryKnownMediaHints({
    this.assetIds = const {},
    this.fingerprints = const {},
    this.filenames = const {},
  });

  final Set<String> assetIds;
  final Set<String> fingerprints;
  final Set<String> filenames;

  bool get isEmpty =>
      assetIds.isEmpty && fingerprints.isEmpty && filenames.isEmpty;

  GalleryKnownMediaHints merge(GalleryKnownMediaHints other) {
    return GalleryKnownMediaHints(
      assetIds: {...assetIds, ...other.assetIds},
      fingerprints: {...fingerprints, ...other.fingerprints},
      filenames: {...filenames, ...other.filenames},
    );
  }

  bool matchesAsset(AssetEntity asset) {
    if (assetIds.contains(asset.id)) return true;
    final fp = galleryAssetFingerprint(asset);
    if (fp != null && fingerprints.contains(fp)) return true;
    final name = GalleryMediaExport.normalizeAlbumBasename(asset.title ?? '');
    if (name.isNotEmpty &&
        galleryFilenameLooksDistinctive(name) &&
        filenames.contains(name)) {
      return true;
    }
    return false;
  }
}
