import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Подробные логи пути «фото → веха» (фильтр в консоли: MilestonePhotoAdd).
abstract final class MilestonePhotoAddTrace {
  static const tag = '[MilestonePhotoAdd]';

  static void step(String step, String message) {
    debugPrint('$tag $step | $message');
  }

  static void fields(String step, Map<String, Object?> data) {
    final body = data.entries
        .map((e) => '${e.key}=${_fmt(e.value)}')
        .join(', ');
    debugPrint('$tag $step | $body');
  }

  static void ids(String step, String label, Iterable<int> ids) {
    final list = ids.toList();
    debugPrint('$tag $step | $label (${list.length}): $list');
  }

  static void galleryBatch(
    String step, {
    required String source,
    required List<Map<String, dynamic>> photos,
    int sample = 8,
  }) {
    final samplePhotos = photos.take(sample).map((photo) {
      final fcId = photo['id'];
      final diaryId = photo['diary_attachment_id'];
      final kind = photo['kind'] ?? photo['media_type'];
      return 'fc=$fcId diary=$diaryId kind=$kind';
    }).join('; ');
    debugPrint(
      '$tag $step | source=$source loaded=${photos.length} sample=[$samplePhotos]',
    );
    final missingDiary = photos.where((p) {
      final raw = p['diary_attachment_id'];
      return raw == null || '$raw'.trim().isEmpty;
    }).length;
    if (missingDiary > 0) {
      debugPrint(
        '$tag $step | WARN: $missingDiary/${photos.length} photos without diary_attachment_id',
      );
    }
  }

  static void linkMap(String step, Map<int, int> fcToDiary) {
    if (fcToDiary.isEmpty) {
      debugPrint('$tag $step | linkMap empty');
      return;
    }
    final pairs = fcToDiary.entries
        .take(12)
        .map((e) => '${e.key}->${e.value}')
        .join(', ');
    debugPrint('$tag $step | linkMap (${fcToDiary.length}): $pairs');
    final unchanged =
        fcToDiary.entries.where((e) => e.key == e.value).length;
    if (unchanged > 0) {
      debugPrint(
        '$tag $step | WARN: $unchanged ids unchanged (fc==diary, mapping may be missing)',
      );
    }
  }

  static void milestone(String step, Map<String, dynamic>? milestone) {
    if (milestone == null) {
      debugPrint('$tag $step | milestone=null');
      return;
    }
    final photos = milestone['photos'];
    final photoCount = photos is List ? photos.length : 0;
    fields(step, {
      'code': milestone['code'],
      'achieved': milestone['achieved'],
      'achieved_at': milestone['achieved_at'],
      'gallery_album_id': milestone['gallery_album_id'],
      'photos_count': photoCount,
    });
  }

  static void apiRequest(
    String step, {
    required String method,
    required String path,
    Object? body,
  }) {
    debugPrint('$tag $step | HTTP $method $path body=${_fmt(body)}');
  }

  static void apiResponse(String step, {required int? status, Object? data}) {
    debugPrint('$tag $step | HTTP status=$status data=${_fmt(data)}');
  }

  static void error(String step, Object error, [StackTrace? stackTrace]) {
    debugPrint('$tag $step | ERROR ${_formatError(error)}');
    if (stackTrace != null) {
      debugPrint('$tag $step | $stackTrace');
    }
  }

  static String _formatError(Object error) {
    if (error is DioException) {
      final buf = StringBuffer('DioException');
      buf.write(' type=${error.type}');
      final status = error.response?.statusCode;
      if (status != null) buf.write(' status=$status');
      buf.write(' ${error.requestOptions.method} ${error.requestOptions.uri}');
      final data = error.response?.data;
      if (data != null) buf.write(' response=${_fmt(data)}');
      if (error.message != null && error.message!.isNotEmpty) {
        buf.write(' message=${error.message}');
      }
      return buf.toString();
    }
    return error.toString();
  }

  static String _fmt(Object? value) {
    if (value == null) return 'null';
    final text = value.toString();
    if (text.length <= 500) return text;
    return '${text.substring(0, 500)}…(${text.length} chars)';
  }
}
