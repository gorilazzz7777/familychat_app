import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/cache/familychat_local_cache.dart';
import '../../../core/network/chat_network_link.dart';
import '../../../core/settings/app_settings.dart';
import '../../familychat/data/familychat_repository.dart';
import 'chat_media_auto_download.dart';
import 'chat_realtime_utils.dart';

enum ChatAttachmentDownloadPhase {
  idle,
  downloading,
  completed,
  failed,
  cancelled,
}

@immutable
class ChatAttachmentDownloadState {
  const ChatAttachmentDownloadState({
    this.phase = ChatAttachmentDownloadPhase.idle,
    this.progress = 0,
  });

  final ChatAttachmentDownloadPhase phase;
  final double progress;

  bool get needsManualTap =>
      phase == ChatAttachmentDownloadPhase.idle ||
      phase == ChatAttachmentDownloadPhase.failed ||
      phase == ChatAttachmentDownloadPhase.cancelled;
}

class ChatAttachmentDownloadManager extends ChangeNotifier {
  ChatAttachmentDownloadManager(this._repo);

  final FamilyChatRepository _repo;
  final Map<String, ChatAttachmentDownloadState> _states = {};
  final Map<String, CancelToken> _tokens = {};
  final Set<String> _manualOnly = {};
  final Map<String, Future<Uint8List?>> _inFlight = {};

  static String keyFor(int threadId, int attachmentId) =>
      '$threadId:$attachmentId';

  ChatAttachmentDownloadState stateFor(int threadId, int attachmentId) {
    return _states[keyFor(threadId, attachmentId)] ??
        const ChatAttachmentDownloadState();
  }

  bool isCompleted(int threadId, int attachmentId) {
    final cached = FamilyChatRepository.peekChatAttachmentBytes(
      threadId,
      attachmentId,
    );
    return cached != null && cached.isNotEmpty;
  }

  void _setState(String key, ChatAttachmentDownloadState state) {
    _states[key] = state;
    notifyListeners();
  }

  Future<void> maybeAutoDownload({
    required int threadId,
    required Map<String, dynamic> attachment,
    required FamilyChatAppSettings settings,
    required ChatNetworkLinkKind network,
    Map<String, dynamic> messageMetadata = const {},
  }) async {
    final attachmentId = chatAsInt(attachment['id']);
    if (attachmentId == null || attachmentId <= 0) return;
    if (ChatMediaAutoDownloadPolicy.isLocallyAvailable(
      threadId: threadId,
      attachment: attachment,
    )) {
      return;
    }

    final cacheKey = keyFor(threadId, attachmentId);
    if (_manualOnly.contains(cacheKey)) return;
    final phase = stateFor(threadId, attachmentId).phase;
    if (phase == ChatAttachmentDownloadPhase.downloading ||
        phase == ChatAttachmentDownloadPhase.completed) {
      return;
    }

    if (!ChatMediaAutoDownloadPolicy.shouldAutoDownload(
      settings: settings,
      network: network,
      attachment: attachment,
      messageMetadata: messageMetadata,
    )) {
      return;
    }

    unawaited(startDownload(threadId: threadId, attachmentId: attachmentId));
  }

  Future<Uint8List?> startDownload({
    required int threadId,
    required int attachmentId,
    bool manual = false,
  }) async {
    final cacheKey = keyFor(threadId, attachmentId);
    if (manual) _manualOnly.remove(cacheKey);

    final cached = FamilyChatRepository.peekChatAttachmentBytes(
      threadId,
      attachmentId,
    );
    if (cached != null && cached.isNotEmpty) {
      _setState(
        cacheKey,
        const ChatAttachmentDownloadState(
          phase: ChatAttachmentDownloadPhase.completed,
          progress: 1,
        ),
      );
      return cached;
    }

    final existing = _inFlight[cacheKey];
    if (existing != null) return existing;

    final token = CancelToken();
    _tokens[cacheKey] = token;
    _setState(
      cacheKey,
      const ChatAttachmentDownloadState(
        phase: ChatAttachmentDownloadPhase.downloading,
        progress: 0,
      ),
    );

    final future = _downloadBody(
      threadId: threadId,
      attachmentId: attachmentId,
      cacheKey: cacheKey,
      token: token,
    );
    _inFlight[cacheKey] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(cacheKey);
      _tokens.remove(cacheKey);
    }
  }

  Future<Uint8List?> _downloadBody({
    required int threadId,
    required int attachmentId,
    required String cacheKey,
    required CancelToken token,
  }) async {
    try {
      final bytes = await _repo.fetchChatAttachmentBytes(
        threadId,
        attachmentId,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          final progress = total > 0 ? received / total : 0.0;
          _setState(
            cacheKey,
            ChatAttachmentDownloadState(
              phase: ChatAttachmentDownloadPhase.downloading,
              progress: progress.clamp(0.0, 1.0),
            ),
          );
        },
      );
      unawaited(
        FamilyChatLocalCache.saveAttachmentBytes(
          threadId,
          attachmentId,
          bytes,
        ).catchError((_) {}),
      );
      _setState(
        cacheKey,
        const ChatAttachmentDownloadState(
          phase: ChatAttachmentDownloadPhase.completed,
          progress: 1,
        ),
      );
      return bytes;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        _manualOnly.add(cacheKey);
        _setState(
          cacheKey,
          const ChatAttachmentDownloadState(
            phase: ChatAttachmentDownloadPhase.cancelled,
          ),
        );
        return null;
      }
      _setState(
        cacheKey,
        const ChatAttachmentDownloadState(
          phase: ChatAttachmentDownloadPhase.failed,
        ),
      );
      return null;
    } catch (_) {
      _setState(
        cacheKey,
        const ChatAttachmentDownloadState(
          phase: ChatAttachmentDownloadPhase.failed,
        ),
      );
      return null;
    }
  }

  void cancelDownload(int threadId, int attachmentId) {
    final cacheKey = keyFor(threadId, attachmentId);
    _tokens[cacheKey]?.cancel('user_cancelled');
    _manualOnly.add(cacheKey);
    _setState(
      cacheKey,
      const ChatAttachmentDownloadState(
        phase: ChatAttachmentDownloadPhase.cancelled,
      ),
    );
  }
}
