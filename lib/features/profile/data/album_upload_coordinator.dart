import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/feed/feed_photo_batch_session.dart';
import '../../../core/media/gallery_media_utils.dart';
import '../../../core/media/image_upload_pipeline.dart';
import '../../../core/media/video_upload_pipeline.dart';
import '../../../core/push/push_message_handler.dart';
import '../../familychat/data/familychat_repository.dart';

class AlbumUploadPhoto {
  const AlbumUploadPhoto({
    required this.bytes,
    required this.filename,
    this.contentType,
    this.photoExif,
    this.kind = 'image',
    this.localPath,
    this.thumbnailBytes,
    this.optimisticKey,
  });

  final Uint8List bytes;
  final String filename;
  final String? contentType;
  final Map<String, dynamic>? photoExif;
  final String kind;
  final String? localPath;
  final Uint8List? thumbnailBytes;
  /// Ключ optimistic-превью в UI альбома (заменяется после upload).
  final String? optimisticKey;
}

class AlbumUploadSession {
  AlbumUploadSession({
    required this.userId,
    required this.albumPk,
    required this.albumId,
    required this.title,
    required this.batchSession,
  });

  final int userId;
  final int albumPk;
  final String albumId;
  final String title;
  final FeedPhotoBatchSession batchSession;
  int total = 0;
  int done = 0;
  int failed = 0;
  bool active = true;
  final List<Map<String, dynamic>> pendingPhotos = [];
}

/// Фоновая загрузка фото в пользовательский альбом (не прерывается при уходе с экрана).
class AlbumUploadCoordinator extends ChangeNotifier {
  AlbumUploadCoordinator._();

  static final AlbumUploadCoordinator instance = AlbumUploadCoordinator._();

  final Map<int, AlbumUploadSession> _sessions = {};
  final Map<int, List<AlbumUploadPhoto>> _queues = {};
  final Set<int> _processing = {};
  final Set<int> _visibleAlbumScreens = {};

  AlbumUploadSession? sessionForAlbum(int albumPk) => _sessions[albumPk];

  bool isActiveForAlbum(int albumPk) {
    final session = _sessions[albumPk];
    return session != null && session.active;
  }

  void setAlbumScreenVisible(int albumPk, bool visible) {
    if (visible) {
      _visibleAlbumScreens.add(albumPk);
    } else {
      _visibleAlbumScreens.remove(albumPk);
    }
  }

  bool isAlbumScreenVisible(int albumPk) => _visibleAlbumScreens.contains(albumPk);

  void clearSession(int albumPk) {
    if (!_sessions.containsKey(albumPk)) return;
    _sessions.remove(albumPk);
    notifyListeners();
  }

  void startUploadToCustomAlbum({
    required FamilyChatRepository repo,
    required int userId,
    required int albumPk,
    required String albumId,
    required String title,
    required List<AlbumUploadPhoto> photos,
    FeedPhotoBatchSession? batchSession,
  }) {
    if (photos.isEmpty) return;

    final existing = _sessions[albumPk];
    late final FeedPhotoBatchSession batch;
    if (batchSession != null) {
      batch = batchSession;
    } else if (existing != null && existing.active) {
      batch = existing.batchSession;
      batch.addTasks(photos.length);
    } else {
      batch = FeedPhotoBatchSession(totalTasks: photos.length);
    }

    if (existing == null || !existing.active) {
      _sessions[albumPk] = AlbumUploadSession(
        userId: userId,
        albumPk: albumPk,
        albumId: albumId,
        title: title,
        batchSession: batch,
      );
      _sessions[albumPk]!.total = photos.length;
    } else {
      existing.total += photos.length;
    }

    final activeSession = _sessions[albumPk]!;
    activeSession.active = true;
    (_queues[albumPk] ??= []).addAll(photos);
    notifyListeners();
    unawaited(_drainQueue(repo: repo, albumPk: albumPk));
  }

  Future<void> _drainQueue({
    required FamilyChatRepository repo,
    required int albumPk,
  }) async {
    if (_processing.contains(albumPk)) return;
    _processing.add(albumPk);

    try {
      while (true) {
        final queue = _queues[albumPk];
        if (queue == null || queue.isEmpty) break;

        final session = _sessions[albumPk];
        if (session == null || !session.active) break;

        final photo = queue.removeAt(0);
        try {
          final prepared = await _prepareForUpload(photo);
          if (prepared == null) {
            session.failed++;
          } else {
            final uploaded = await repo.uploadPhotoToCustomAlbum(
              session.userId,
              session.albumPk,
              bytes: prepared.bytes,
              filename: prepared.filename,
              contentType: prepared.contentType ?? 'image/jpeg',
              batchId: session.batchSession.batchId,
              photoExif: prepared.photoExif,
            );
            if (photo.optimisticKey != null) {
              uploaded['_optimistic_key'] = photo.optimisticKey;
            }
            session.pendingPhotos.add(uploaded);
            session.done++;
          }
        } catch (_) {
          session.failed++;
        } finally {
          await session.batchSession.markAttemptFinished(repo);
        }
        notifyListeners();
      }

      final session = _sessions[albumPk];
      final remaining = _queues[albumPk];
      if (session == null || (remaining != null && remaining.isNotEmpty)) return;

      session.active = false;
      if (!isAlbumScreenVisible(albumPk)) {
        _showGlobalSummary(session);
        _sessions.remove(albumPk);
      }
      _queues.remove(albumPk);
      notifyListeners();
    } finally {
      _processing.remove(albumPk);
      final remaining = _queues[albumPk];
      if (remaining != null && remaining.isNotEmpty) {
        unawaited(_drainQueue(repo: repo, albumPk: albumPk));
      }
    }
  }

  void _showGlobalSummary(AlbumUploadSession session) {
    final message = session.failed == 0
        ? '«${session.title}»: загружено ${session.done}'
        : '«${session.title}»: загружено ${session.done}, ошибок ${session.failed}';
    familyChatScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  List<Map<String, dynamic>> takePendingPhotos(int albumPk) {
    final session = _sessions[albumPk];
    if (session == null || session.pendingPhotos.isEmpty) return const [];
    final photos = List<Map<String, dynamic>>.from(session.pendingPhotos);
    session.pendingPhotos.clear();
    return photos;
  }

  static Future<AlbumUploadPhoto?> _prepareForUpload(AlbumUploadPhoto photo) async {
    if (photo.kind == 'video') {
      final draft = await prepareVideoUploadDraft(
        originalBytes: photo.bytes,
        filename: photo.filename,
        contentType: photo.contentType ?? contentTypeForFilename(photo.filename),
        localPath: photo.localPath,
      );
      if (!draft.canUpload) return null;
      return AlbumUploadPhoto(
        bytes: draft.bytesForUpload,
        filename: draft.filename,
        contentType: draft.contentType,
        photoExif: draft.geo?.toPhotoExif() ?? photo.photoExif,
        kind: 'video',
        optimisticKey: photo.optimisticKey,
      );
    }
    final draft = await prepareImageUploadDraft(
      originalBytes: photo.bytes,
      filename: photo.filename,
      contentType: photo.contentType,
      previewBytes: photo.thumbnailBytes,
      localPath: photo.localPath,
    );
    if (!draft.canUpload) return null;
    return AlbumUploadPhoto(
      bytes: draft.bytesForUpload,
      filename: draft.filename,
      contentType: draft.contentType,
      photoExif: draft.geo?.toPhotoExif() ?? photo.photoExif,
      kind: 'image',
      optimisticKey: photo.optimisticKey,
    );
  }
}
