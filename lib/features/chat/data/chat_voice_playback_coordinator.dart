import 'dart:async';

import 'chat_realtime_utils.dart';
import 'chat_voice_utils.dart';

/// One-at-a-time voice playback + autoplay of the next consecutive voice bubble.
class ChatVoicePlaybackCoordinator {
  ChatVoicePlaybackCoordinator._();

  static final ChatVoicePlaybackCoordinator instance =
      ChatVoicePlaybackCoordinator._();

  static const playbackRates = <double>[1.0, 1.25, 1.5, 2.0, 3.0];

  final Map<int, ChatVoicePlayerHandle> _handles = {};
  List<({int messageIndex, int attachmentId})> _sequence = const [];
  int? _activeAttachmentId;
  double _playbackRate = 1.0;

  int? get activeAttachmentId => _activeAttachmentId;
  double get playbackRate => _playbackRate;

  String get playbackRateLabel {
    final r = _playbackRate;
    if (r == 1.0) return '1×';
    if (r == 1.25) return '1.25×';
    if (r == 1.5) return '1.5×';
    if (r == 2.0) return '2×';
    if (r == 3.0) return '3×';
    return '$r×';
  }

  double cyclePlaybackRate() {
    final i = playbackRates.indexOf(_playbackRate);
    final next = playbackRates[(i < 0 ? 0 : i + 1) % playbackRates.length];
    _playbackRate = next;
    for (final handle in _handles.values) {
      unawaited(handle.applyRate(next));
    }
    return next;
  }

  /// [messages] must be chronological oldest→newest (same order as FC `_messages`
  /// / TG timeline before reverse). Autoplay advances to the next voice only when
  /// it is the immediately following message («ниже по чату»).
  void syncFromMessages(List<Map<String, dynamic>> messages) {
    final next = <({int messageIndex, int attachmentId})>[];
    for (var i = 0; i < messages.length; i++) {
      final id = firstVoiceAttachmentId(messages[i]);
      if (id != null && id > 0) {
        next.add((messageIndex: i, attachmentId: id));
      }
    }
    _sequence = next;
  }

  /// Same contract as [syncFromMessages], for screens that already know voice ids
  /// per chronological row (null / ≤0 = not a voice bubble).
  void syncFromVoiceAttachmentIds(List<int?> voiceAttachmentIdByMessage) {
    final next = <({int messageIndex, int attachmentId})>[];
    for (var i = 0; i < voiceAttachmentIdByMessage.length; i++) {
      final id = voiceAttachmentIdByMessage[i];
      if (id != null && id > 0) {
        next.add((messageIndex: i, attachmentId: id));
      }
    }
    _sequence = next;
  }

  void register(int attachmentId, ChatVoicePlayerHandle handle) {
    _handles[attachmentId] = handle;
  }

  void unregister(int attachmentId, ChatVoicePlayerHandle handle) {
    if (identical(_handles[attachmentId], handle)) {
      _handles.remove(attachmentId);
    }
    if (_activeAttachmentId == attachmentId) {
      _activeAttachmentId = null;
    }
  }

  Future<void> notifyStarted(int attachmentId) async {
    _activeAttachmentId = attachmentId;
    final others = _handles.entries
        .where((e) => e.key != attachmentId)
        .map((e) => e.value)
        .toList();
    for (final handle in others) {
      await handle.pauseIfPlaying();
    }
  }

  Future<void> notifyCompleted(int attachmentId) async {
    if (_activeAttachmentId == attachmentId) {
      _activeAttachmentId = null;
    }
    final idx = _sequence.indexWhere((e) => e.attachmentId == attachmentId);
    if (idx < 0 || idx + 1 >= _sequence.length) return;
    final current = _sequence[idx];
    final next = _sequence[idx + 1];
    // Only autoplay when the next voice is the immediately following message.
    if (next.messageIndex != current.messageIndex + 1) return;
    // Next bubble may mount one frame later (TG list keepAlives=false).
    for (var attempt = 0; attempt < 6; attempt++) {
      final handle = _handles[next.attachmentId];
      if (handle != null) {
        await handle.playFromAutoplay();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  static int? firstVoiceAttachmentId(Map<String, dynamic> message) {
    final metaRaw = message['metadata'];
    final meta = metaRaw is Map
        ? metaRaw.map((k, v) => MapEntry(k.toString(), v))
        : null;
    for (final att in chatAttachmentsOf(message)) {
      if (!isVoiceAttachment(att, messageMetadata: meta)) continue;
      return chatAsInt(att['id']);
    }
    return null;
  }
}

class ChatVoicePlayerHandle {
  const ChatVoicePlayerHandle({
    required this.pauseIfPlaying,
    required this.playFromAutoplay,
    required this.applyRate,
  });

  final Future<void> Function() pauseIfPlaying;
  final Future<void> Function() playFromAutoplay;
  final Future<void> Function(double rate) applyRate;
}
