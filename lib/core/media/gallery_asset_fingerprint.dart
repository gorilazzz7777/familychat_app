import 'package:photo_manager/photo_manager.dart';

import 'gallery_media_export.dart';

/// Ядро отпечатка без имени файла (дата / размер / длительность).
String? galleryAssetFingerprintCore(AssetEntity asset) {
  final createdMs = asset.createDateTime.millisecondsSinceEpoch;
  if (createdMs <= 0 && asset.width <= 0 && asset.height <= 0) return null;
  return '${createdMs}_${asset.width}x${asset.height}_${asset.duration}';
}

/// Лёгкий отпечаток ассета галереи телефона (без чтения байтов).
///
/// На iOS копия в альбоме FamilyChat получает другой `asset.id`, но обычно
/// сохраняет дату съёмки / размер кадра / title — по ним можно узнать оригинал
/// в «Недавние».
String? galleryAssetFingerprint(AssetEntity asset) {
  final core = galleryAssetFingerprintCore(asset);
  if (core == null) return null;
  final title = GalleryMediaExport.normalizeAlbumBasename(asset.title ?? '');
  return '${core}_$title';
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
    // Title на iOS у копии в альбоме часто другой — матчим ядро без имени.
    final core = galleryAssetFingerprintCore(asset);
    if (core != null) {
      for (final known in fingerprints) {
        if (known == core || known.startsWith('${core}_')) return true;
      }
    }
    final name = GalleryMediaExport.normalizeAlbumBasename(asset.title ?? '');
    if (name.isNotEmpty &&
        galleryFilenameLooksDistinctive(name) &&
        filenames.contains(name)) {
      return true;
    }
    return false;
  }

  /// kDebugMode: почему ассет не подсветился / подсветился.
  String debugMatchReason(AssetEntity asset) {
    if (assetIds.contains(asset.id)) return 'assetId';
    final fp = galleryAssetFingerprint(asset);
    if (fp != null && fingerprints.contains(fp)) return 'fingerprint';
    final core = galleryAssetFingerprintCore(asset);
    if (core != null) {
      for (final known in fingerprints) {
        if (known == core || known.startsWith('${core}_')) {
          return 'fingerprint_core';
        }
      }
    }
    final name = GalleryMediaExport.normalizeAlbumBasename(asset.title ?? '');
    if (name.isNotEmpty &&
        galleryFilenameLooksDistinctive(name) &&
        filenames.contains(name)) {
      return 'filename';
    }
    return 'none asset=${asset.id} title=${asset.title} fp=$fp '
        'knownAssets=${assetIds.length} knownFp=${fingerprints.length} '
        'knownNames=${filenames.length}';
  }
}
