import 'package:exif/exif.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/debug/upload_image_exif_log.dart';
import '../../familychat/data/familychat_repository.dart';

class CalendarPhotoSyncInfo {
  CalendarPhotoSyncInfo({
    required this.eventId,
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.syncUntil,
    required this.galleryAlbumId,
    required this.autoSyncPhotos,
    required this.syncActive,
    required this.syncedDeviceAssetIds,
    this.stagingAlbumId,
    this.pendingReviewCount = 0,
  });

  factory CalendarPhotoSyncInfo.fromJson(Map<String, dynamic> json) {
    return CalendarPhotoSyncInfo(
      eventId: json['event_id'] as int? ?? int.parse('${json['event_id']}'),
      title: json['title']?.toString() ?? '',
      startDate: DateTime.parse(json['start_date']!.toString()),
      endDate: DateTime.parse(json['end_date']!.toString()),
      syncUntil: DateTime.parse(json['sync_until']!.toString()),
      galleryAlbumId: json['gallery_album_id'] as int? ??
          int.parse('${json['gallery_album_id']}'),
      stagingAlbumId: json['staging_album_id'] is int
          ? json['staging_album_id'] as int
          : int.tryParse('${json['staging_album_id'] ?? ''}'),
      autoSyncPhotos: json['auto_sync_photos'] == true,
      syncActive: json['sync_active'] == true,
      pendingReviewCount: json['pending_review_count'] is int
          ? json['pending_review_count'] as int
          : int.tryParse('${json['pending_review_count'] ?? 0}') ?? 0,
      syncedDeviceAssetIds: (json['synced_device_asset_ids'] as List? ?? const [])
          .map((e) => e.toString())
          .toSet(),
    );
  }

  final int eventId;
  final String title;
  final DateTime startDate;
  final DateTime endDate;
  final DateTime syncUntil;
  final int galleryAlbumId;
  final int? stagingAlbumId;
  final bool autoSyncPhotos;
  final bool syncActive;
  final int pendingReviewCount;
  final Set<String> syncedDeviceAssetIds;

  bool containsDate(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final until = DateTime(syncUntil.year, syncUntil.month, syncUntil.day);
    return !d.isBefore(start) && !d.isAfter(until);
  }
}

class CalendarDevicePhoto {
  CalendarDevicePhoto({
    required this.deviceAssetId,
    required this.filename,
    required this.bytes,
    required this.takenAt,
    this.contentType,
  });

  final String deviceAssetId;
  final String filename;
  final Uint8List bytes;
  final DateTime? takenAt;
  final String? contentType;
}

class CalendarPhotoSyncService {
  CalendarPhotoSyncService(this._repo);

  final FamilyChatRepository _repo;
  static const _dailyReviewKey = 'familychat_calendar_staging_review_day';

  static bool get isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<CalendarPhotoSyncInfo?> fetchAlbumSyncInfo(int albumPk) async {
    try {
      final data = await _repo.fetchCalendarAlbumPhotoSync(albumPk);
      return CalendarPhotoSyncInfo.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<List<CalendarPhotoSyncInfo>> fetchActiveSyncs() async {
    final list = await _repo.activeCalendarPhotoSyncs();
    return list.map(CalendarPhotoSyncInfo.fromJson).toList();
  }

  Future<List<CalendarPhotoSyncInfo>> fetchPendingReviews() async {
    final list = await _repo.pendingCalendarPhotoReviews();
    return list.map(CalendarPhotoSyncInfo.fromJson).toList();
  }

  Future<bool> shouldShowDailyReviewPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final key = '${today.year}-${today.month}-${today.day}';
    return prefs.getString(_dailyReviewKey) != key;
  }

  Future<void> markDailyReviewPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final key = '${today.year}-${today.month}-${today.day}';
    await prefs.setString(_dailyReviewKey, key);
  }

  /// Фоновая загрузка с камеры — только во временный альбом.
  Future<int> syncAndroidCameraPhotos({
    required int userId,
    required CalendarPhotoSyncInfo info,
    void Function(int done, int total)? onProgress,
  }) async {
    if (!isAndroidNative || !info.autoSyncPhotos || !info.syncActive) return 0;
    final stagingAlbumId = info.stagingAlbumId;
    if (stagingAlbumId == null) return 0;

    final permitted = await PhotoManager.requestPermissionExtend();
    if (!permitted.isAuth) return 0;

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: false,
    );
    AssetPathEntity? cameraPath;
    for (final path in paths) {
      final name = path.name.toLowerCase();
      if (name.contains('camera') || name == 'камера') {
        cameraPath = path;
        break;
      }
    }
    cameraPath ??= paths.isNotEmpty ? paths.first : null;
    if (cameraPath == null) return 0;

    final count = await cameraPath.assetCountAsync;
    if (count == 0) return 0;

    final start = DateTime(info.startDate.year, info.startDate.month, info.startDate.day);
    final until = DateTime(
      info.syncUntil.year,
      info.syncUntil.month,
      info.syncUntil.day,
      23,
      59,
      59,
      999,
    );

    final candidates = <AssetEntity>[];
    const chunk = 200;
    for (var offset = 0; offset < count; offset += chunk) {
      final end = (offset + chunk > count) ? count : offset + chunk;
      final batch = await cameraPath.getAssetListRange(start: offset, end: end);
      for (final asset in batch) {
        if (info.syncedDeviceAssetIds.contains(asset.id)) continue;
        final created = asset.createDateTime;
        if (created.isBefore(start) || created.isAfter(until)) continue;
        candidates.add(asset);
      }
    }

    if (candidates.isEmpty) return 0;

    var uploaded = 0;
    final registered = <String>[];
    final attachmentByDevice = <String, int>{};
    for (var i = 0; i < candidates.length; i++) {
      onProgress?.call(i, candidates.length);
      final asset = candidates[i];
      final file = await asset.originFile ?? await asset.file;
      if (file == null) continue;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) continue;
      final title = await asset.titleAsync;
      final filename = (title.isNotEmpty) ? title : 'photo_${asset.id}.jpg';
      await logUploadImageExifDiagnostics(
        bytes: bytes,
        filename: filename,
        sourcePath: file.path,
        readVia: 'photo_manager_originFile',
      );
      try {
        final result = await _repo.uploadPhotoToCustomAlbum(
          userId,
          stagingAlbumId,
          bytes: bytes,
          filename: filename,
        );
        final attId = result['id'] is int
            ? result['id'] as int
            : int.tryParse('${result['id'] ?? result['attachment_id'] ?? ''}');
        registered.add(asset.id);
        if (attId != null) attachmentByDevice[asset.id] = attId;
        uploaded++;
      } catch (_) {
        // continue
      }
    }

    if (registered.isNotEmpty) {
      await _repo.registerCalendarSyncedAssets(
        info.galleryAlbumId,
        registered,
        attachmentIdsByDevice: attachmentByDevice,
      );
    }
    onProgress?.call(candidates.length, candidates.length);
    return uploaded;
  }

  Future<List<CalendarDevicePhoto>> pickWebPhotosWithDateFilter(
    CalendarPhotoSyncInfo info,
  ) async {
    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
      type: FileType.image,
    );
    if (picked == null || picked.files.isEmpty) return [];

    final out = <CalendarDevicePhoto>[];
    for (final file in picked.files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      final takenAt = await _readTakenAt(bytes) ?? fileIdentifierDate(file);
      final assetId = '${file.identifier ?? file.name}_${bytes.length}';
      out.add(
        CalendarDevicePhoto(
          deviceAssetId: assetId,
          filename: file.name,
          bytes: bytes,
          takenAt: takenAt,
          contentType: _imageContentType(file.name),
        ),
      );
    }
    return out;
  }

  Future<int> uploadDevicePhotos({
    required int userId,
    required CalendarPhotoSyncInfo info,
    required List<CalendarDevicePhoto> photos,
  }) async {
    final stagingAlbumId = info.stagingAlbumId ?? info.galleryAlbumId;
    final registered = <String>[];
    final attachmentByDevice = <String, int>{};
    var uploaded = 0;
    for (final photo in photos) {
      if (info.syncedDeviceAssetIds.contains(photo.deviceAssetId)) continue;
      try {
        final result = await _repo.uploadPhotoToCustomAlbum(
          userId,
          stagingAlbumId,
          bytes: photo.bytes,
          filename: photo.filename,
          contentType: photo.contentType,
        );
        final attId = result['id'] is int
            ? result['id'] as int
            : int.tryParse('${result['id'] ?? result['attachment_id'] ?? ''}');
        registered.add(photo.deviceAssetId);
        if (attId != null) attachmentByDevice[photo.deviceAssetId] = attId;
        uploaded++;
      } catch (_) {}
    }
    if (registered.isNotEmpty) {
      await _repo.registerCalendarSyncedAssets(
        info.galleryAlbumId,
        registered,
        attachmentIdsByDevice: attachmentByDevice,
      );
    }
    return uploaded;
  }

  Future<DateTime?> _readTakenAt(Uint8List bytes) async {
    try {
      final tags = await readExifFromBytes(bytes);
      final raw = tags['EXIF DateTimeOriginal']?.printable ??
          tags['Image DateTime']?.printable;
      if (raw == null || raw.isEmpty) return null;
      final parts = raw.split(' ');
      if (parts.length < 2) return null;
      final d = parts[0].split(':');
      final t = parts[1].split(':');
      if (d.length < 3 || t.length < 3) return null;
      final year = int.tryParse(d[0]);
      final month = int.tryParse(d[1]);
      final day = int.tryParse(d[2]);
      if (year == null || month == null || day == null) return null;
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }

  DateTime? fileIdentifierDate(PlatformFile file) => null;

  String? _imageContentType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }
}

Future<int> runActiveAndroidCalendarSync({
  required FamilyChatRepository repo,
  required int userId,
}) async {
  if (!CalendarPhotoSyncService.isAndroidNative) return 0;
  final service = CalendarPhotoSyncService(repo);
  final active = await service.fetchActiveSyncs();
  var total = 0;
  for (final info in active) {
    total += await service.syncAndroidCameraPhotos(userId: userId, info: info);
  }
  return total;
}
