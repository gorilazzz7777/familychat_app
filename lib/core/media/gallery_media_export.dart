import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../cache/familychat_media_cache.dart';
import 'gallery_media_utils.dart';

/// Экспорт фото/видео галереи: share из кэша и сохранение в папку приложения.
abstract final class GalleryMediaExport {
  /// Имя альбома/папки в галерее телефона (FamilyChat).
  static const String appAlbumName = 'FamilyChat';

  /// Партнёрский альбом Dairy: те же файлы могли уже лежать там после sync.
  static const String diaryPartnerAlbumName = 'LittleOne';

  /// Альбомы, в которых ищем уже сохранённый файл по имени (сначала свой).
  static const List<String> localLookupAlbumNames = [
    appAlbumName,
    diaryPartnerAlbumName,
  ];

  /// Session cache: normalized filename -> MediaStore / Photos asset id.
  static final Map<String, String> _knownAppAlbumAssetIds = {};

  /// Cached Photos album localIdentifier so we reuse one FamilyChat album.
  /// iOS [createAlbum] always creates a *new* collection (same title allowed).
  static String? _cachedIosAppAlbumId;

  /// Serializes album lookup/create — concurrent saves otherwise each call
  /// [createAlbum] and produce one album per photo.
  static Future<AssetPathEntity?>? _iosAppAlbumEnsureInflight;

  /// After a successful consolidate this session, skip re-scanning duplicates.
  static bool _iosDuplicatesCleaned = false;

  static String filenameFor(Map<String, dynamic> attachment, {int? id}) {
    final raw = attachment['filename']?.toString().trim() ?? '';
    if (raw.isNotEmpty) return raw;
    final aid = id ??
        (attachment['id'] is int
            ? attachment['id'] as int
            : int.tryParse('${attachment['id']}'));
    if (isVideoAttachment(attachment)) {
      return 'video_${aid ?? DateTime.now().millisecondsSinceEpoch}.mp4';
    }
    return 'photo_${aid ?? DateTime.now().millisecondsSinceEpoch}.jpg';
  }

  static String mimeForName(String name) => contentTypeForFilename(name);

  static String normalizeAlbumFilename(String name) {
    final base = name.trim().toLowerCase();
    if (base.isEmpty) return '';
    return base.replaceAll(RegExp(r'\s*\(\d+\)(?=\.[^.]+$)'), '');
  }

  static void rememberAppAlbumAsset(String filename, String assetId) {
    final key = normalizeAlbumFilename(filename);
    if (key.isEmpty || assetId.isEmpty) return;
    _knownAppAlbumAssetIds[key] = assetId;
  }

  /// Id ассетов в альбомах FamilyChat / LittleOne на телефоне (копии уже сохранённых фото).
  static Future<Set<String>> appAlbumAssetIds({int maxAssets = 2000}) async {
    if (kIsWeb) return {};
    final ids = <String>{
      for (final id in _knownAppAlbumAssetIds.values)
        if (id.trim().isNotEmpty) id.trim(),
    };
    try {
      final filter = FilterOptionGroup(
        imageOption: const FilterOption(needTitle: true),
        videoOption: const FilterOption(needTitle: true),
      );
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        filterOption: filter,
      );
      for (final albumName in localLookupAlbumNames) {
        AssetPathEntity? album;
        for (final path in paths) {
          if (path.name == albumName) {
            album = path;
            break;
          }
        }
        if (album == null) continue;
        final count = await album.assetCountAsync;
        final limit = count > maxAssets ? maxAssets : count;
        const pageSize = 200;
        for (var start = 0; start < limit; start += pageSize) {
          final end = start + pageSize > limit ? limit : start + pageSize;
          final assets = await album.getAssetListRange(start: start, end: end);
          for (final asset in assets) {
            ids.add(asset.id);
            final title = asset.title?.trim() ?? '';
            if (title.isNotEmpty) {
              rememberAppAlbumAsset(title, asset.id);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[GalleryMediaExport] appAlbumAssetIds failed: $e');
    }
    return ids;
  }

  /// Найти уже сохранённый файл в FamilyChat или LittleOne с тем же именем.
  static Future<AssetEntity?> findExistingInAppAlbum(String filename) async {
    final want = normalizeAlbumFilename(filename);
    if (want.isEmpty) return null;

    final cachedId = _knownAppAlbumAssetIds[want];
    if (cachedId != null && cachedId.isNotEmpty) {
      try {
        final cached = await AssetEntity.fromId(cachedId);
        if (cached != null) return cached;
      } catch (_) {}
      _knownAppAlbumAssetIds.remove(want);
    }

    try {
      final filter = FilterOptionGroup(
        imageOption: const FilterOption(needTitle: true),
        videoOption: const FilterOption(needTitle: true),
      );
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        filterOption: filter,
      );
      final albums = <AssetPathEntity>[];
      for (final albumName in localLookupAlbumNames) {
        for (final path in paths) {
          if (path.name == albumName) {
            albums.add(path);
            break;
          }
        }
      }
      if (albums.isEmpty) return null;

      for (final album in albums) {
        final found = await _findAssetInAlbum(album, want);
        if (found != null) {
          rememberAppAlbumAsset(filename, found.id);
          return found;
        }
      }
    } catch (e) {
      debugPrint('[GalleryMediaExport] findExisting failed: $e');
    }
    return null;
  }

  static Future<AssetEntity?> _findAssetInAlbum(
    AssetPathEntity album,
    String wantNormalized,
  ) async {
    final count = await album.assetCountAsync;
    const pageSize = 100;
    for (var start = 0; start < count; start += pageSize) {
      final end = start + pageSize > count ? count : start + pageSize;
      final assets = await album.getAssetListRange(start: start, end: end);
      for (final asset in assets) {
        var title = asset.title?.trim() ?? '';
        if (title.isEmpty) {
          try {
            title = (await asset.titleAsync).trim();
          } catch (_) {}
        }
        if (normalizeAlbumFilename(title) != wantNormalized) continue;
        return asset;
      }
    }
    return null;
  }

  /// Файл из дискового кэша превью/полноэкранного просмотра (без сети).
  static Future<File?> fileFromDiskCache(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    for (final manager in [
      FamilyChatMediaCache.fullscreen,
      FamilyChatMediaCache.preview,
    ]) {
      try {
        final info = await manager.getFileFromCache(trimmed);
        final file = info?.file;
        if (file != null && await file.exists() && await file.length() > 0) {
          return file;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Байты: кэш 뿯↽ (опционально) сеть через [fetchBytes].
  static Future<Uint8List> resolveBytes({
    required Map<String, dynamic> attachment,
    Future<Uint8List> Function()? fetchBytes,
  }) async {
    final url = galleryAttachmentUrl(attachment);
    final cached = await fileFromDiskCache(url);
    if (cached != null) {
      return cached.readAsBytes();
    }

    // Догрузить в кэш по публичному URL, если есть.
    if (url.isNotEmpty) {
      try {
        final file = await FamilyChatMediaCache.fullscreen.getSingleFile(url);
        if (await file.exists() && await file.length() > 0) {
          return file.readAsBytes();
        }
      } catch (_) {}
    }

    if (fetchBytes != null) {
      final bytes = await fetchBytes();
      if (bytes.isNotEmpty) return bytes;
    }
    throw StateError('Не удалось получить файл');
  }

  /// Локальный файл для share (реальный путь — иначе share_plus зависает).
  static Future<XFile> toShareXFile({
    required Map<String, dynamic> attachment,
    Future<Uint8List> Function()? fetchBytes,
  }) async {
    final name = filenameFor(attachment);
    final url = galleryAttachmentUrl(attachment);
    final cached = await fileFromDiskCache(url);
    if (cached != null) {
      // Копия с понятным именем — share sheet иногда берёт имя из path.
      final tmp = await _copyToTemp(cached, name);
      return XFile(tmp.path, name: name, mimeType: mimeForName(name));
    }

    final bytes = await resolveBytes(
      attachment: attachment,
      fetchBytes: fetchBytes,
    );
    final tmp = await _writeTemp(bytes, name);
    return XFile(tmp.path, name: name, mimeType: mimeForName(name));
  }

  static Future<void> shareAttachments({
    required List<Map<String, dynamic>> attachments,
    Future<Uint8List> Function(Map<String, dynamic> attachment)? fetchBytes,
    Rect? sharePositionOrigin,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Share на web не поддерживается');
    }
    final files = <XFile>[];
    for (final attachment in attachments) {
      files.add(
        await toShareXFile(
          attachment: attachment,
          fetchBytes: fetchBytes == null
              ? null
              : () => fetchBytes(attachment),
        ),
      );
    }
    if (files.isEmpty) {
      throw StateError('Не удалось подготовить файлы');
    }
    await SharePlus.instance.share(
      ShareParams(
        files: files,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  /// Сохранить в галерею: папка приложения, иначе общая Pictures/Camera Roll.
  static Future<void> saveAttachmentsToGallery({
    required List<Map<String, dynamic>> attachments,
    Future<Uint8List> Function(Map<String, dynamic> attachment)? fetchBytes,
  }) async {
    if (kIsWeb) {
      throw UnsupportedError('Сохранение в галерею на web не поддерживается');
    }
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      throw StateError('Нет доступа к галерее телефона');
    }

    var saved = 0;
    for (final attachment in attachments) {
      final name = filenameFor(attachment);
      if (isVideoAttachment(attachment)) {
        final x = await toShareXFile(
          attachment: attachment,
          fetchBytes: fetchBytes == null
              ? null
              : () => fetchBytes(attachment),
        );
        await _saveVideoFile(File(x.path), filename: name);
      } else {
        final bytes = await resolveBytes(
          attachment: attachment,
          fetchBytes: fetchBytes == null
              ? null
              : () => fetchBytes(attachment),
        );
        await _saveImageBytes(bytes, filename: name);
      }
      saved += 1;
    }
    if (saved == 0) {
      throw StateError('Не удалось сохранить файлы');
    }
  }

  static Future<void> _saveImageBytes(
    Uint8List bytes, {
    required String filename,
  }) async {
    final existing = await findExistingInAppAlbum(filename);
    if (existing != null) return;

    try {
      final entity = await PhotoManager.editor.saveImage(
        bytes,
        filename: filename,
        title: filename,
        relativePath: 'Pictures/$appAlbumName',
      );
      await tryAddToIosAlbum(entity);
      rememberAppAlbumAsset(filename, entity.id);
      return;
    } catch (_) {}

    final entity = await PhotoManager.editor.saveImage(
      bytes,
      filename: filename,
      title: filename,
    );
    await tryAddToIosAlbum(entity);
    rememberAppAlbumAsset(filename, entity.id);
  }

  static Future<void> _saveVideoFile(
    File file, {
    required String filename,
  }) async {
    final existing = await findExistingInAppAlbum(filename);
    if (existing != null) return;

    try {
      final entity = await PhotoManager.editor.saveVideo(
        file,
        title: filename,
        relativePath: 'Pictures/$appAlbumName',
      );
      await tryAddToIosAlbum(entity);
      rememberAppAlbumAsset(filename, entity.id);
      return;
    } catch (_) {}

    final entity = await PhotoManager.editor.saveVideo(
      file,
      title: filename,
    );
    await tryAddToIosAlbum(entity);
    rememberAppAlbumAsset(filename, entity.id);
  }

  static Future<void> tryAddToIosAlbum(AssetEntity entity) async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    try {
      final album = await _ensureIosAppAlbum();
      if (album == null) return;
      await PhotoManager.editor.copyAssetToPath(
        asset: entity,
        pathEntity: album,
      );
    } catch (e) {
      // Уже лежит в общей галерее / нет прав на альбом.
      debugPrint('[GalleryMediaExport] tryAddToIosAlbum failed: $e');
    }
  }

  /// One shared user album named [appAlbumName], created at most once.
  static Future<AssetPathEntity?> _ensureIosAppAlbum() {
    final inflight = _iosAppAlbumEnsureInflight;
    if (inflight != null) return inflight;

    final future = _ensureIosAppAlbumImpl();
    _iosAppAlbumEnsureInflight = future;
    future.whenComplete(() {
      if (identical(_iosAppAlbumEnsureInflight, future)) {
        _iosAppAlbumEnsureInflight = null;
      }
    });
    return future;
  }

  static Future<AssetPathEntity?> _ensureIosAppAlbumImpl() async {
    final cachedId = _cachedIosAppAlbumId?.trim() ?? '';
    if (cachedId.isNotEmpty) {
      try {
        final cached = await AssetPathEntity.fromId(cachedId);
        if (cached.id.isNotEmpty) {
          _cachedIosAppAlbumId = cached.id;
          if (!_iosDuplicatesCleaned) {
            await _consolidateIosAppAlbumsKeeping(cached);
            _iosDuplicatesCleaned = true;
          }
          return cached;
        }
      } catch (_) {
        _cachedIosAppAlbumId = null;
      }
    }

    final matches = await _listIosAppAlbumsByName();
    if (matches.isNotEmpty) {
      final keeper = await _consolidateIosAppAlbums(matches);
      _cachedIosAppAlbumId = keeper.id;
      _iosDuplicatesCleaned = true;
      return keeper;
    }

    final created =
        await PhotoManager.editor.darwin.createAlbum(appAlbumName);
    if (created != null) {
      _cachedIosAppAlbumId = created.id;
      _iosDuplicatesCleaned = true;
    }
    return created;
  }

  static Future<List<({AssetPathEntity path, int count})>>
      _listIosAppAlbumsByName() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      pathFilterOption: const PMPathFilter(
        darwin: PMDarwinPathFilter(
          type: [PMDarwinAssetCollectionType.album],
          subType: [PMDarwinAssetCollectionSubtype.any],
        ),
      ),
    );

    final out = <({AssetPathEntity path, int count})>[];
    for (final path in paths) {
      if (path.name != appAlbumName) continue;
      final count = await path.assetCountAsync;
      out.add((path: path, count: count));
    }
    return out;
  }

  /// Keep the fullest album, move photos from the rest, delete duplicates.
  static Future<AssetPathEntity> _consolidateIosAppAlbums(
    List<({AssetPathEntity path, int count})> matches,
  ) async {
    if (matches.length == 1) return matches.first.path;

    matches.sort((a, b) => b.count.compareTo(a.count));
    final keeper = matches.first.path;
    final duplicates = matches.skip(1).map((m) => m.path).toList();
    await _mergeAndDeleteIosAlbums(keeper: keeper, duplicates: duplicates);
    return keeper;
  }

  static Future<void> _consolidateIosAppAlbumsKeeping(
    AssetPathEntity keeper,
  ) async {
    final matches = await _listIosAppAlbumsByName();
    if (matches.length <= 1) return;
    final duplicates = <AssetPathEntity>[];
    for (final m in matches) {
      if (m.path.id == keeper.id) continue;
      duplicates.add(m.path);
    }
    if (duplicates.isEmpty) return;
    await _mergeAndDeleteIosAlbums(keeper: keeper, duplicates: duplicates);
  }

  static Future<void> _mergeAndDeleteIosAlbums({
    required AssetPathEntity keeper,
    required List<AssetPathEntity> duplicates,
  }) async {
    for (final dup in duplicates) {
      try {
        final count = await dup.assetCountAsync;
        if (count > 0) {
          const pageSize = 80;
          for (var start = 0; start < count; start += pageSize) {
            final end = start + pageSize > count ? count : start + pageSize;
            final assets =
                await dup.getAssetListRange(start: start, end: end);
            for (final asset in assets) {
              try {
                await PhotoManager.editor.copyAssetToPath(
                  asset: asset,
                  pathEntity: keeper,
                );
              } catch (_) {
                // Уже в keeper / нет прав — пропускаем кадр.
              }
            }
          }
        }
        final deleted =
            await PhotoManager.editor.darwin.deletePath(dup);
        if (!deleted) {
          debugPrint(
            '[GalleryMediaExport] could not delete duplicate album id=${dup.id}',
          );
        }
      } catch (e) {
        debugPrint(
          '[GalleryMediaExport] consolidate album failed id=${dup.id}: $e',
        );
      }
    }
  }

  static Future<File> _writeTemp(Uint8List bytes, String name) async {
    final dir = await getTemporaryDirectory();
    final safe = name.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final file = File(
      '${dir.path}/fc_export_${DateTime.now().microsecondsSinceEpoch}_$safe',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<File> _copyToTemp(File source, String name) async {
    final dir = await getTemporaryDirectory();
    final safe = name.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    final file = File(
      '${dir.path}/fc_share_${DateTime.now().microsecondsSinceEpoch}_$safe',
    );
    await source.copy(file.path);
    return file;
  }
}
