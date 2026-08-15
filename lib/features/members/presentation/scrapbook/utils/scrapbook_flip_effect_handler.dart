import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:real_page_flip/real_page_flip.dart';

/// Обход бага real_page_flip 1.12.14: после `stop()` вызывается `resume()`,
/// а в audioplayers 6.x это no-op — звук листания молчит при живой вибрации.
class ScrapbookFlipEffectHandler implements PageFlipEffectHandler {
  ScrapbookFlipEffectHandler({
    PaperTexturePreset hapticTexturePreset = PaperTexturePreset.kraft,
  }) : _haptics = DefaultPageFlipEffectHandler(
          hapticTexturePreset: hapticTexturePreset,
        ) {
    unawaited(_initAudio());
  }

  static const _mp3Asset =
      'packages/real_page_flip/assets/sounds/page_flip.mp3';
  static const _opusAsset =
      'packages/real_page_flip/assets/sounds/page_flip.opus';
  static const _poolSize = 3;

  final DefaultPageFlipEffectHandler _haptics;
  final List<AudioPlayer> _pool = List.generate(_poolSize, (_) => AudioPlayer());
  int _poolIndex = 0;
  bool _audioReady = false;
  String _assetPath = _mp3Asset;

  Future<void> _initAudio() async {
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.ambient,
            options: const {AVAudioSessionOptions.mixWithOthers},
          ),
        ),
      );
    } on Object {
      // Context is best-effort; playback may still work with defaults.
    }

    var ok = false;
    for (final player in _pool) {
      try {
        await player.setPlayerMode(PlayerMode.lowLatency);
        player.audioCache.prefix = '';
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(AssetSource(_mp3Asset));
        _assetPath = _mp3Asset;
        ok = true;
      } on Object {
        try {
          await player.setPlayerMode(PlayerMode.lowLatency);
          player.audioCache.prefix = '';
          await player.setReleaseMode(ReleaseMode.stop);
          await player.setSource(AssetSource(_opusAsset));
          _assetPath = _opusAsset;
          ok = true;
        } on Object {
          // Ignore init failures for this pool slot.
        }
      }
    }
    _audioReady = ok;
  }

  void _playSound(double volume) {
    if (!_audioReady) return;
    // Чуть громче дефолтного 0.05–0.35 — иначе на части устройств почти не слышно.
    final capped = (volume * 0.65).clamp(0.2, 0.75);
    final player = _pool[_poolIndex];
    _poolIndex = (_poolIndex + 1) % _poolSize;
    unawaited(_playOnPlayer(player, capped));
  }

  Future<void> _playOnPlayer(AudioPlayer player, double volume) async {
    try {
      await player.stop();
      await player.setVolume(volume);
      // Важно: play(), не resume() — иначе звука нет на audioplayers 6.x.
      await player.play(AssetSource(_assetPath), volume: volume);
    } on Object {
      // Keep flips alive if audio fails.
    }
  }

  @override
  set viewportWidth(double width) {
    _haptics.viewportWidth = width;
  }

  @override
  FutureOr<void> onHandleEffect(
    PageFlipEvent event, {
    int? pageIndex,
    int? intensity,
    double? volume,
    double? texture,
    double? resistance,
  }) {
    if (event == PageFlipEvent.sound) {
      _playSound(volume ?? 1.0);
      return null;
    }
    return _haptics.onHandleEffect(
      event,
      pageIndex: pageIndex,
      intensity: intensity,
      volume: volume,
      texture: texture,
      resistance: resistance,
    );
  }

  @override
  void dispose() {
    _audioReady = false;
    for (final player in _pool) {
      player.dispose();
    }
    _haptics.dispose();
  }
}
