import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../debug/upload_image_exif_log.dart';
import 'image_upload_pipeline.dart';
import 'video_upload_pipeline.dart';

/// GPS из PhotoKit или оригинального HEIC.
///
/// На iOS `asset.file` — JPEG без GPS; координаты живут в PhotoKit
/// и в `originBytes` / `originFile`.
Future<MediaGeo?> extractMediaGeoFromAsset(AssetEntity asset) async {
  if (asset.type != AssetType.image && asset.type != AssetType.video) {
    return null;
  }

  final fromSync = mediaGeoFromCoordinates(asset.latitude, asset.longitude);
  if (fromSync != null) {
    logAssetGeoHint(
      assetId: asset.id,
      source: 'photokit_sync',
      geo: fromSync,
    );
    return fromSync;
  }

  try {
    final asyncLatLng = await asset.latlngAsync();
    final fromAsync = mediaGeoFromCoordinates(
      asyncLatLng?.latitude,
      asyncLatLng?.longitude,
    );
    if (fromAsync != null) {
      logAssetGeoHint(
        assetId: asset.id,
        source: 'photokit_async',
        geo: fromAsync,
      );
      return fromAsync;
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('extractMediaGeoFromAsset latlngAsync failed: $e');
    }
  }

  if (asset.type != AssetType.image) {
    logAssetGeoHint(assetId: asset.id, source: 'none', geo: null);
    return null;
  }

  try {
    final origin = await asset.originBytes;
    if (origin != null && origin.isNotEmpty) {
      final fromOrigin = await extractMediaGeoFromImageBytes(origin);
      if (fromOrigin != null) {
        logAssetGeoHint(
          assetId: asset.id,
          source: 'origin_bytes',
          geo: fromOrigin,
        );
        return fromOrigin;
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('extractMediaGeoFromAsset originBytes failed: $e');
    }
  }

  try {
    final file = await asset.originFile;
    if (file != null) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        final fromFile = await extractMediaGeoFromImageBytes(bytes);
        if (fromFile != null) {
          logAssetGeoHint(
            assetId: asset.id,
            source: 'origin_file',
            geo: fromFile,
          );
          return fromFile;
        }
      }
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('extractMediaGeoFromAsset originFile failed: $e');
    }
  }

  logAssetGeoHint(assetId: asset.id, source: 'none', geo: null);
  return null;
}
