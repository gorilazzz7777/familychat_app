import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/session_log.dart';

/// Raise-to-listen for voice messages — thin Dart side of Telegram
/// `MediaController` listen path:
///
/// - Native decides `wantFrontSpeaker` (proximity + raise + headset forbid).
/// - On change: one `setAudioContext` (media vs voiceCommunication) + one
///   player restart (`startAudioAgain`). No native reassert / debounce races.
class VoicePlaybackProximityRoute {
  VoicePlaybackProximityRoute._();

  static final VoicePlaybackProximityRoute instance =
      VoicePlaybackProximityRoute._();

  static const _methods = MethodChannel('com.familychat/voice_proximity');
  static const _events = EventChannel('com.familychat/voice_proximity_events');

  int _playingCount = 0;
  bool _listening = false;
  bool _hasSensor = false;
  bool _pipelineReady = false;
  bool _wantFrontSpeaker = false;
  StreamSubscription<dynamic>? _eventSub;
  Timer? _stopDebounce;
  DateTime? _playStartedAt;
  int _routeApplySeq = 0;
  bool _routeApplying = false;

  /// Active voice bubble registers a restart so we can swap MUSIC↔VOICE_CALL.
  Future<void> Function({required bool earpiece})? routeRestartHandler;
  Object? _routeHandlerToken;

  void attachRouteRestart(
    Object token,
    Future<void> Function({required bool earpiece}) handler,
  ) {
    _routeHandlerToken = token;
    routeRestartHandler = handler;
  }

  void detachRouteRestart(Object token) {
    if (!identical(_routeHandlerToken, token)) return;
    _routeHandlerToken = null;
    routeRestartHandler = null;
  }

  void _log(String evt, [Map<String, Object?> fields = const {}]) {
    SessionLog.instance.event('voice.prox', evt, {
      'playingCount': _playingCount,
      'listening': _listening,
      'hasSensor': _hasSensor,
      'wantFront': _wantFrontSpeaker,
      'pipelineReady': _pipelineReady,
      if (_playStartedAt != null)
        'playAgeMs': DateTime.now().difference(_playStartedAt!).inMilliseconds,
      ...fields,
    });
  }

  /// Call once before [AudioPlayer.play] so the track opens on speaker/media.
  static Future<void> prepareForPlayback() async {
    if (kIsWeb) return;
    await instance._preparePipeline();
  }

  /// Legacy alias — scrapbook / non-proximity callers.
  static Future<void> ensureDefaultSpeakerContext() => prepareForPlayback();

  Future<void> _preparePipeline() async {
    if (_pipelineReady && _listening) {
      _log('prepare_skip', {'why': 'already-ready'});
      return;
    }
    _log('prepare_begin');
    try {
      final has = await _methods.invokeMethod<bool>('start') ?? false;
      _hasSensor = has;
      _listening = true;
      _wantFrontSpeaker = false;
      _log('prepare_sensor', {'hasSensor': has});
      // Attach native events even if AudioContext setup fails — otherwise
      // raise-to-listen runs native-only and Dart never restarts the player.
      _eventSub ??= _events.receiveBroadcastStream().listen(
        _onNativeEvent,
        onError: (Object e) {
          _log('stream_error', {'err': '$e'});
          debugPrint('voice proximity stream error: $e');
        },
      );
      await AudioPlayer.global.setAudioContext(_speakerContext);
      _log('audio_context', {'kind': 'speaker', 'why': 'prepare'});
      await _methods.invokeMethod<void>('setSpeaker');
      _pipelineReady = true;
    } catch (e) {
      _log('prepare_fail', {'err': '$e'});
      debugPrint('voice proximity prepare failed: $e');
      _pipelineReady = false;
      try {
        await AudioPlayer.global.setAudioContext(_speakerContextFallback);
        _pipelineReady = true;
        _log('audio_context', {
          'kind': 'speakerFallback',
          'why': 'prepare_fail',
        });
      } catch (e2) {
        _log('prepare_fallback_fail', {'err': '$e2'});
      }
    }
  }

  void _onNativeEvent(dynamic event) {
    if (event is! Map) return;
    final reason = event['reason']?.toString() ?? '';
    final wantFront = event['wantFrontSpeaker'] == true;
    final near = event['near'] == true;
    _log('native_event', {
      'reason': reason,
      'wantFront': wantFront,
      'prevWantFront': _wantFrontSpeaker,
      'near': near,
      'raised': event['raised'] == true,
      'headsetForbidden': event['headsetForbidden'] == true,
      'voiceProxHeld': event['voiceProxHeld'] == true,
      if (event['dist'] != null) 'dist': event['dist'],
    });
    if (!_listening || _playingCount <= 0) return;
    if (wantFront == _wantFrontSpeaker) return;
    _wantFrontSpeaker = wantFront;
    unawaited(_applyRoute(why: reason.isEmpty ? 'native' : reason));
  }

  /// Call when any voice player enters [PlayerState.playing].
  Future<void> onPlaying() async {
    if (kIsWeb) return;
    _stopDebounce?.cancel();
    _playingCount++;
    _playStartedAt ??= DateTime.now();
    _log('onPlaying');
    if (_playingCount == 1) {
      if (!_pipelineReady) await _preparePipeline();
      try {
        await _methods.invokeMethod<void>('setPlaying', {'playing': true});
      } catch (e) {
        _log('setPlaying_fail', {'err': '$e'});
      }
    }
  }

  /// Call when a voice player leaves playing (pause / complete / dispose).
  Future<void> onNotPlaying() async {
    if (kIsWeb) return;
    if (_playingCount > 0) _playingCount--;
    _log('onNotPlaying');
    _stopDebounce?.cancel();
    _stopDebounce = Timer(const Duration(milliseconds: 350), () async {
      if (_playingCount == 0) {
        await _stopListening();
      }
    });
  }

  /// Context for the active [AudioPlayer] — global alone is not enough:
  /// audioplayers keeps the WrappedPlayer's old context until
  /// `player.setAudioContext` (USAGE_MEDIA stays on loudspeaker).
  static AudioContext contextFor({required bool earpiece}) =>
      earpiece ? _earpieceContext : _speakerContext;

  Future<void> _applyRoute({required String why}) async {
    final seq = ++_routeApplySeq;
    if (!_listening || _playingCount <= 0) {
      _log('route_skip', {'why': 'not-playing', 'seq': seq});
      return;
    }
    if (_routeApplying) {
      _log('route_skip', {'why': 'in-flight', 'seq': seq});
      return;
    }
    _routeApplying = true;
    final earpiece = _wantFrontSpeaker;
    final ctx = contextFor(earpiece: earpiece);
    _log('route_apply_begin', {'earpiece': earpiece, 'why': why, 'seq': seq});
    try {
      // Seed default for future players; existing player is updated in restart.
      await AudioPlayer.global.setAudioContext(ctx);
      _log('audio_context', {
        'kind': earpiece ? 'earpiece' : 'speaker',
        'why': why,
        'scope': 'global',
      });
      final restart = routeRestartHandler;
      if (restart != null) {
        await restart(earpiece: earpiece);
        _log('route_restart', {'earpiece': earpiece});
      } else {
        _log('route_restart_skip', {'why': 'no-handler'});
      }
      // audioplayers global setAudioContext applies the *previous* context to
      // AudioManager (off-by-one). Re-assert TG speakerphone after player
      // reopen so Samsung does not stay on the loudspeaker.
      try {
        await _methods.invokeMethod<void>(
          earpiece ? 'setEarpiece' : 'setSpeaker',
        );
        _log('native_reassert', {'earpiece': earpiece, 'why': 'post-restart'});
      } catch (e) {
        _log('native_reassert_fail', {'err': '$e'});
      }
    } catch (e) {
      _log('route_apply_fail', {'err': '$e', 'seq': seq});
      debugPrint('voice proximity route failed: $e');
    } finally {
      _routeApplying = false;
      if (seq != _routeApplySeq && _listening && _playingCount > 0) {
        unawaited(_applyRoute(why: 'coalesce'));
      }
    }
  }

  Future<void> _stopListening() async {
    _log('stop_begin');
    _stopDebounce?.cancel();
    _stopDebounce = null;
    routeRestartHandler = null;
    _routeHandlerToken = null;
    await _eventSub?.cancel();
    _eventSub = null;
    if (_listening) {
      try {
        await _methods.invokeMethod<void>('setPlaying', {'playing': false});
      } catch (_) {}
      try {
        await _methods.invokeMethod<void>('stop');
      } catch (e) {
        _log('stop_native_fail', {'err': '$e'});
      }
    }
    _listening = false;
    _hasSensor = false;
    _pipelineReady = false;
    _wantFrontSpeaker = false;
    _playStartedAt = null;
    try {
      await AudioPlayer.global.setAudioContext(_speakerContext);
      _log('audio_context', {'kind': 'speaker', 'why': 'stop'});
    } catch (_) {}
    _log('stop_done');
  }

  /// Loudspeaker / media — TG default for voice tap.
  ///
  /// audioplayers asserts: `defaultToSpeaker` only with `playAndRecord`, so
  /// speaker uses playAndRecord+defaultToSpeaker (not bare `playback`).
  static final AudioContext _speakerContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {
        AVAudioSessionOptions.allowBluetooth,
        AVAudioSessionOptions.allowBluetoothA2DP,
        AVAudioSessionOptions.defaultToSpeaker,
      },
    ),
  );

  /// Fallback if the preferred speaker context still fails to apply.
  static final AudioContext _speakerContextFallback = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {},
    ),
  );

  /// Earpiece / voice-call stream — TG front speaker path.
  static final AudioContext _earpieceContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: true,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.voiceCommunication,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {
        AVAudioSessionOptions.allowBluetooth,
        AVAudioSessionOptions.allowBluetoothA2DP,
      },
    ),
  );
}
