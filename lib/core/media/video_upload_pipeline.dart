import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';

import 'gallery_media_utils.dart';

/// Лимиты загрузки видео Family Chat.
const int kMaxVideoOriginalBytes = 100 * 1024 * 1024; // 100 МБ
const int kMaxVideoUploadBytes = 40 * 1024 * 1024; // целевой потолок после сжатия
const int kSoftVideoUploadBytes = 30 * 1024 * 1024;

enum MediaDraftKind { image, video, file }

class MediaGeo {
  const MediaGeo({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  Map<String, dynamic> toPhotoExif() => {
        'gps_latitude': latitude,
        'gps_longitude': longitude,
      };
}

/// Один элемент перед отправкой (фото/видео), с превью и валидацией.
class MediaUploadDraft {
  MediaUploadDraft({
    required this.id,
    required this.kind,
    required this.filename,
    required this.contentType,
    required this.originalBytes,
    this.localPath,
    this.thumbnailBytes,
    this.preparedBytes,
    this.geo,
    this.tooLarge = false,
    this.errorMessage,
    this.previewBroken = false,
  });

  final String id;
  final MediaDraftKind kind;
  final String filename;
  String contentType;
  final Uint8List originalBytes;
  String? localPath;
  Uint8List? thumbnailBytes;
  Uint8List? preparedBytes;
  MediaGeo? geo;
  bool tooLarge;
  String? errorMessage;
  bool previewBroken;

  bool get isVideo => kind == MediaDraftKind.video;
  bool get isImage => kind == MediaDraftKind.image;
  bool get canUpload => !tooLarge && (preparedBytes ?? originalBytes).isNotEmpty;

  Uint8List get bytesForUpload => preparedBytes ?? originalBytes;

  int get displaySizeBytes => (preparedBytes ?? originalBytes).length;
}

MediaDraftKind mediaDraftKindFor({
  required String filename,
  String? contentType,
  Uint8List? bytes,
}) {
  final ct = (contentType ?? contentTypeForFilename(filename)).toLowerCase();
  if (ct.startsWith('video/') ||
      isVideoAttachment({
        'kind': 'video',
        'filename': filename,
        'content_type': ct,
      })) {
    return MediaDraftKind.video;
  }
  if (ct.startsWith('image/') ||
      isImageAttachment({
        'kind': 'image',
        'filename': filename,
        'content_type': ct,
      })) {
    return MediaDraftKind.image;
  }
  // ftyp встречается и у видео (mp4/mov), и у HEIC/HEIF.
  // На web HEIC часто приходит без корректного mime, поэтому различаем по major brand.
  if (bytes != null &&
      bytes.length >= 12 &&
      bytes[4] == 0x66 &&
      bytes[5] == 0x74 &&
      bytes[6] == 0x79 &&
      bytes[7] == 0x70) {
    final majorBrand = String.fromCharCodes(bytes.sublist(8, 12))
        .toLowerCase()
        .trim();
    const imageBrands = {'heic', 'heix', 'hevc', 'hevx', 'heif', 'mif1', 'msf1'};
    if (imageBrands.contains(majorBrand)) {
      return MediaDraftKind.image;
    }
    const videoBrands = {'mp41', 'mp42', 'isom', 'iso2', 'avc1', 'qt  '};
    if (videoBrands.contains(majorBrand)) {
      return MediaDraftKind.video;
    }
  }
  return MediaDraftKind.file;
}

Future<MediaGeo?> captureDeviceGeoIfPossible() async {
  try {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return null;
    }
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 8),
      ),
    );
    return MediaGeo(latitude: pos.latitude, longitude: pos.longitude);
  } catch (_) {
    return null;
  }
}

typedef VideoProgressCallback = void Function(double progress, String label);

/// Подготовка видео: проверка размера → гео → сжатие 720→640→480 → превью.
Future<MediaUploadDraft> prepareVideoUploadDraft({
  required Uint8List originalBytes,
  required String filename,
  String? contentType,
  String? localPath,
  MediaGeo? geoHint,
  VideoProgressCallback? onProgress,
}) async {
  final id = 'v_${DateTime.now().microsecondsSinceEpoch}';
  final ct = contentType ?? contentTypeForFilename(filename);
  final draft = MediaUploadDraft(
    id: id,
    kind: MediaDraftKind.video,
    filename: filename,
    contentType: ct,
    originalBytes: originalBytes,
    localPath: localPath,
  );

  if (originalBytes.length > kMaxVideoOriginalBytes) {
    draft.tooLarge = true;
    draft.errorMessage =
        'Видео больше 100 МБ и не будет загружено';
    await _attachThumbnail(draft);
    return draft;
  }

  onProgress?.call(0.05, 'Геоданные…');
  draft.geo = geoHint ?? await captureDeviceGeoIfPossible();

  onProgress?.call(0.1, 'Превью…');
  await _attachThumbnail(draft);

  // Уже уложились — без сжатия.
  if (originalBytes.length <= kMaxVideoUploadBytes) {
    draft.preparedBytes = originalBytes;
    onProgress?.call(1, 'Готово');
    return draft;
  }

  if (kIsWeb) {
    // На web нет video_compress: >40 МБ помечаем ошибкой.
    draft.tooLarge = true;
    draft.errorMessage =
        'В браузере сжатие недоступно. Выберите видео до 40 МБ '
        'или отправьте из приложения';
    return draft;
  }

  final path = await _ensureLocalPath(draft);
  if (path == null) {
    draft.tooLarge = true;
    draft.errorMessage = 'Не удалось подготовить видео к сжатию';
    return draft;
  }

  // Лестница качества ≈ 720 → 640 → 480.
  final ladder = <VideoQuality>[
    VideoQuality.Res1280x720Quality,
    VideoQuality.Res960x540Quality,
    VideoQuality.Res640x480Quality,
  ];
  final labels = ['720p', '540p', '480p'];

  Uint8List? best;
  for (var i = 0; i < ladder.length; i++) {
    final step = (i + 1) / ladder.length;
    onProgress?.call(0.15 + step * 0.8, 'Сжатие ${labels[i]}…');
    try {
      final info = await VideoCompress.compressVideo(
        path,
        quality: ladder[i],
        deleteOrigin: false,
        includeAudio: true,
      );
      final outPath = info?.path;
      if (outPath == null || outPath.isEmpty) continue;
      final out = await File(outPath).readAsBytes();
      if (out.isEmpty) continue;
      best = Uint8List.fromList(out);
      if (best.length <= kMaxVideoUploadBytes) {
        draft.preparedBytes = best;
        // Нормализуем расширение для загруженного mp4.
        if (!draft.filename.toLowerCase().endsWith('.mp4')) {
          draft.contentType = 'video/mp4';
        }
        onProgress?.call(1, 'Готово');
        return draft;
      }
    } catch (_) {
      // пробуем следующую ступень
    }
  }

  if (best != null && best.length <= kMaxVideoOriginalBytes) {
    // Не уложились в 40 МБ даже на 480p.
    draft.tooLarge = true;
    draft.errorMessage =
        'Видео слишком большое даже после сжатия и не будет загружено';
    draft.preparedBytes = best;
    onProgress?.call(1, 'Слишком большое');
    return draft;
  }

  draft.tooLarge = true;
  draft.errorMessage =
      'Не удалось сжать видео до допустимого размера';
  onProgress?.call(1, 'Ошибка');
  return draft;
}

Future<void> _attachThumbnail(MediaUploadDraft draft) async {
  try {
    if (kIsWeb) {
      draft.previewBroken = true;
      return;
    }
    final path = await _ensureLocalPath(draft);
    if (path == null) {
      draft.previewBroken = true;
      return;
    }
    final file = await VideoCompress.getFileThumbnail(
      path,
      quality: 60,
      position: -1,
    );
    draft.thumbnailBytes = await file.readAsBytes();
  } catch (_) {
    draft.previewBroken = true;
  }
}

Future<String?> _ensureLocalPath(MediaUploadDraft draft) async {
  if (draft.localPath != null && draft.localPath!.isNotEmpty) {
    final f = File(draft.localPath!);
    if (await f.exists()) return draft.localPath;
  }
  if (kIsWeb) return null;
  try {
    final dir = await getTemporaryDirectory();
    final ext = draft.filename.contains('.')
        ? draft.filename.split('.').last
        : 'mp4';
    final file = File('${dir.path}/${draft.id}.$ext');
    await file.writeAsBytes(draft.originalBytes, flush: true);
    draft.localPath = file.path;
    return file.path;
  } catch (_) {
    return null;
  }
}

String encodePhotoExifFormField(MediaGeo? geo) {
  if (geo == null) return '';
  return jsonEncode(geo.toPhotoExif());
}
