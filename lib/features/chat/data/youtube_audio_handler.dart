import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Background / lock-screen playback for YouTube proxy streams.
class YoutubeAudioHandler extends BaseAudioHandler with SeekHandler {
  YoutubeAudioHandler() {
    _player.playbackEventStream.listen(_broadcastState);
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        stop();
      }
    });
  }

  final AudioPlayer _player = AudioPlayer();

  AudioPlayer get player => _player;

  /// Load URL into the player without starting playback (foreground video owns audio).
  Future<void> prepareUrl({
    required String url,
    required MediaItem item,
    Duration? position,
  }) async {
    mediaItem.add(item);
    await _player.setUrl(url);
    if (position != null && position > Duration.zero) {
      await _player.seek(position);
    }
    await pause();
  }

  Future<void> playUrl({
    required String url,
    required MediaItem item,
    Duration? position,
  }) async {
    await prepareUrl(url: url, item: item, position: position);
    await play();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  void _broadcastState(PlaybackEvent event) {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: const {
          ProcessingState.idle: AudioProcessingState.idle,
          ProcessingState.loading: AudioProcessingState.loading,
          ProcessingState.buffering: AudioProcessingState.buffering,
          ProcessingState.ready: AudioProcessingState.ready,
          ProcessingState.completed: AudioProcessingState.completed,
        }[_player.processingState]!,
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  @override
  Future<void> fastForward() =>
      seek(_player.position + const Duration(seconds: 15));

  @override
  Future<void> rewind() {
    final next = _player.position - const Duration(seconds: 15);
    return seek(next < Duration.zero ? Duration.zero : next);
  }
}

YoutubeAudioHandler? _youtubeHandler;
Completer<YoutubeAudioHandler>? _initCompleter;

/// Lazy singleton — only spins AudioService when YouTube playback starts.
Future<YoutubeAudioHandler> ensureYoutubeAudioHandler() async {
  final existing = _youtubeHandler;
  if (existing != null) return existing;
  final pending = _initCompleter;
  if (pending != null) return pending.future;
  final c = Completer<YoutubeAudioHandler>();
  _initCompleter = c;
  try {
    final handler = await AudioService.init(
      builder: YoutubeAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'familychat_youtube',
        androidNotificationChannelName: 'YouTube',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'drawable/ic_stat_youtube',
        fastForwardInterval: Duration(seconds: 15),
        rewindInterval: Duration(seconds: 15),
      ),
    );
    _youtubeHandler = handler;
    c.complete(handler);
    return handler;
  } catch (e, st) {
    _initCompleter = null;
    c.completeError(e, st);
    rethrow;
  }
}
