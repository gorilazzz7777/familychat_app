import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../diagnostics/session_log.dart';

/// Loudspeaker by default; earpiece while the proximity sensor says «near».
///
/// Do **not** recreate [AudioContext] / AVAudioSession category on each
/// near↔far flip — that tears down the AudioTrack and causes ~1–2s mute.
/// Open one routable communication pipeline **before** [play], then only
/// toggle speakerphone / output port. Skip screen-off wake lock (pauses
/// Flutter and produces the same mute).
///
/// Debug: every step goes to [SessionLog] cat=`voice.prox` / `voice.snap`
/// (same JSONL as tg/fc diag under `fc_diag/`).
class VoicePlaybackProximityRoute {
  VoicePlaybackProximityRoute._();

  static final VoicePlaybackProximityRoute instance =
      VoicePlaybackProximityRoute._();

  static const _methods = MethodChannel('com.familychat/voice_proximity');
  static const _events = EventChannel('com.familychat/voice_proximity_events');

  int _playingCount = 0;
  bool _listening = false;
  bool _near = false;
  bool _hasSensor = false;
  bool _pipelineReady = false;
  StreamSubscription<dynamic>? _eventSub;
  Timer? _stopDebounce;
  Timer? _routeDebounce;
  Timer? _snapHeartbeat;
  DateTime? _playStartedAt;
  int _routeApplySeq = 0;
  /// Android often drops MODE_IN_COMMUNICATION → NORMAL mid-play (SessionLog
  /// 14:01: near@ear then mode=NORMAL while speakerOn=false → quiet/wrong).
  int _routeDriftStreak = 0;
  bool _reassertInFlight = false;

  void _log(String evt, [Map<String, Object?> fields = const {}]) {
    SessionLog.instance.event('voice.prox', evt, {
      'playingCount': _playingCount,
      'listening': _listening,
      'hasSensor': _hasSensor,
      'near': _near,
      'pipelineReady': _pipelineReady,
      if (_playStartedAt != null)
        'playAgeMs': DateTime.now().difference(_playStartedAt!).inMilliseconds,
      ...fields,
    });
  }

  /// Call once before [AudioPlayer.play] so the track opens on the final usage.
  static Future<void> prepareForPlayback() async {
    if (kIsWeb) return;
    await instance._preparePipeline();
  }

  /// Legacy alias — scrapbook / non-proximity callers.
  static Future<void> ensureDefaultSpeakerContext() => prepareForPlayback();

  Future<void> _preparePipeline() async {
    if (_pipelineReady && _listening) {
      _log('prepare_skip', {'why': 'already-ready'});
      await _logNativeSnapshot('prepare_skip');
      return;
    }
    _log('prepare_begin');
    try {
      final has = await _methods.invokeMethod<bool>('start') ?? false;
      _hasSensor = has;
      _listening = true;
      _log('prepare_sensor', {'hasSensor': has});
      if (has) {
        await AudioPlayer.global.setAudioContext(_routableContext);
        _log('audio_context', {
          'kind': 'routable',
          'androidUsage': 'voiceCommunication',
          'iosCategory': 'playAndRecord',
        });
        await _methods.invokeMethod<void>('setSpeaker');
        _log('native_setSpeaker', {'why': 'prepare'});
        _eventSub ??= _events.receiveBroadcastStream().listen(
          _onNativeEvent,
          onError: (Object e) {
            _log('stream_error', {'err': '$e'});
            debugPrint('voice proximity stream error: $e');
          },
        );
      } else {
        await AudioPlayer.global.setAudioContext(_speakerOnlyContext);
        _log('audio_context', {
          'kind': 'speakerOnly',
          'why': 'no-sensor',
        });
      }
      _pipelineReady = true;
      await _logNativeSnapshot('prepare_done');
    } catch (e) {
      _log('prepare_fail', {'err': '$e'});
      debugPrint('voice proximity prepare failed: $e');
      _listening = false;
      _hasSensor = false;
      _pipelineReady = false;
      try {
        await AudioPlayer.global.setAudioContext(_speakerOnlyContext);
      } catch (_) {}
    }
  }

  void _onNativeEvent(dynamic event) {
    final parsed = _parseNearEvent(event);
    final near = parsed.near;
    _log('sensor_event', {
      'near': near,
      'prevNear': _near,
      'changed': near != _near,
      if (parsed.raw is Map) 'raw': _stringifyMap(parsed.raw as Map),
      if (parsed.raw is! Map) 'raw': '$event',
      if (parsed.dist != null) 'dist': parsed.dist,
      if (parsed.maxRange != null) 'maxRange': parsed.maxRange,
      if (parsed.extra.isNotEmpty) ...parsed.extra,
    });
    if (near == _near) return;
    _near = near;
    _scheduleRouteApply(why: 'sensor');
  }

  static String _stringifyMap(Map raw) {
    try {
      return raw.entries.map((e) => '${e.key}=${e.value}').join(' ');
    } catch (_) {
      return '$raw';
    }
  }

  ({
    bool near,
    double? dist,
    double? maxRange,
    dynamic raw,
    Map<String, Object?> extra,
  }) _parseNearEvent(dynamic event) {
    if (event is Map) {
      final near = event['near'] == true ||
          event['near'] == 1 ||
          event['near'] == 'near';
      final dist = (event['dist'] as num?)?.toDouble();
      final maxRange = (event['maxRange'] as num?)?.toDouble();
      final extra = <String, Object?>{};
      for (final key in [
        'mode',
        'speakerOn',
        'musicVol',
        'voiceVol',
        'ringVol',
        'wiredHeadset',
        'btA2dp',
        'btSco',
        'reason',
      ]) {
        if (event[key] != null) extra[key] = event[key];
      }
      return (
        near: near,
        dist: dist,
        maxRange: maxRange,
        raw: event,
        extra: extra,
      );
    }
    final near = event == true || event == 1 || event == 'near';
    return (near: near, dist: null, maxRange: null, raw: event, extra: const {});
  }

  /// Call when any voice player enters [PlayerState.playing].
  Future<void> onPlaying() async {
    if (kIsWeb) return;
    _stopDebounce?.cancel();
    _playingCount++;
    _playStartedAt ??= DateTime.now();
    _log('onPlaying');
    if (_playingCount == 1 && !_pipelineReady) {
      await _preparePipeline();
    }
    _armSnapHeartbeat();
    await _logNativeSnapshot('onPlaying');
  }

  /// Call when a voice player leaves playing (pause / complete / dispose).
  Future<void> onNotPlaying() async {
    if (kIsWeb) return;
    if (_playingCount > 0) _playingCount--;
    _log('onNotPlaying');
    _stopDebounce?.cancel();
    // Autoplays the next bubble within a few frames — keep the sensor warm.
    _stopDebounce = Timer(const Duration(milliseconds: 350), () async {
      if (_playingCount == 0) {
        await _stopListening();
      }
    });
    if (_playingCount == 0) {
      _snapHeartbeat?.cancel();
      _snapHeartbeat = null;
    }
  }

  void _armSnapHeartbeat() {
    _snapHeartbeat?.cancel();
    _routeDriftStreak = 0;
    // Dense while playing — volume keys / cheek taps / route flaps show up.
    _snapHeartbeat = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_playingCount <= 0) return;
      unawaited(_heartbeatTick());
    });
  }

  Future<void> _heartbeatTick() async {
    final snap = await _logNativeSnapshot('heartbeat');
    if (snap == null || _playingCount <= 0 || !_pipelineReady) return;
    await _maybeReassertRoute(snap, why: 'heartbeat');
  }

  /// Keep MODE_IN_COMMUNICATION + speakerphone matching [_near] while playing.
  Future<void> _maybeReassertRoute(
    Map snap, {
    required String why,
  }) async {
    if (!_listening || !_hasSensor || _reassertInFlight) return;
    final modeInt = (snap['modeInt'] as num?)?.toInt() ?? -1;
    final speakerOn = snap['speakerOn'] == true;
    final wantSpeaker = !_near;
    // MODE_IN_COMMUNICATION == 3. Anything else mid-play is drift.
    final modeOk = modeInt == 3;
    final speakerOk = speakerOn == wantSpeaker;
    if (modeOk && speakerOk) {
      _routeDriftStreak = 0;
      return;
    }
    _routeDriftStreak++;
    // One bad sample can be a transient flip during setSpeaker — wait ~800ms.
    if (_routeDriftStreak < 2) {
      _log('route_drift', {
        'why': why,
        'streak': _routeDriftStreak,
        'modeInt': modeInt,
        'speakerOn': speakerOn,
        'wantSpeaker': wantSpeaker,
        'near': _near,
      });
      return;
    }
    _routeDriftStreak = 0;
    _reassertInFlight = true;
    try {
      _log('route_reassert', {
        'why': why,
        'modeInt': modeInt,
        'speakerOn': speakerOn,
        'wantSpeaker': wantSpeaker,
        'near': _near,
      });
      final seq = ++_routeApplySeq;
      await _applyNativeRouteOnly(why: 'reassert:$why', seq: seq);
    } finally {
      _reassertInFlight = false;
    }
  }

  void _scheduleRouteApply({required String why}) {
    final seq = ++_routeApplySeq;
    _log('route_debounce', {'why': why, 'targetNear': _near, 'seq': seq});
    _routeDebounce?.cancel();
    // Proximity sensors often chatter for ~100–200ms when covering.
    _routeDebounce = Timer(const Duration(milliseconds: 120), () {
      unawaited(_applyNativeRouteOnly(why: why, seq: seq));
    });
  }

  Future<void> _applyNativeRouteOnly({
    required String why,
    required int seq,
  }) async {
    if (!_listening || !_hasSensor) {
      _log('route_skip', {'why': 'not-listening', 'seq': seq});
      return;
    }
    if (seq != _routeApplySeq) {
      _log('route_skip', {'why': 'stale-seq', 'seq': seq, 'cur': _routeApplySeq});
      return;
    }
    final method = _near ? 'setEarpiece' : 'setSpeaker';
    _log('route_apply_begin', {'method': method, 'why': why, 'seq': seq});
    await _logNativeSnapshot('route_before');
    try {
      // Native speakerphone / port toggle only — never setAudioContext here.
      await _methods.invokeMethod<void>(method);
      _routeDriftStreak = 0;
      _log('route_apply_ok', {'method': method, 'why': why, 'seq': seq});
    } catch (e) {
      _log('route_apply_fail', {'method': method, 'err': '$e', 'seq': seq});
      debugPrint('voice proximity route failed: $e');
    }
    await _logNativeSnapshot('route_after');
  }

  Future<Map<dynamic, dynamic>?> _logNativeSnapshot(String why) async {
    try {
      final snap = await _methods.invokeMethod<dynamic>('getSnapshot');
      if (snap is Map) {
        if (SessionLog.enabled) {
          SessionLog.instance.event('voice.snap', why, {
            'playingCount': _playingCount,
            'near': _near,
            for (final e in snap.entries)
              if (e.value != null) '${e.key}': e.value,
          });
        }
        return snap;
      }
      if (SessionLog.enabled) {
        SessionLog.instance.event('voice.snap', why, {
          'playingCount': _playingCount,
          'raw': '$snap',
        });
      }
      return null;
    } catch (e) {
      if (SessionLog.enabled) {
        SessionLog.instance.event('voice.snap', 'fail', {
          'why': why,
          'err': '$e',
        });
      }
      return null;
    }
  }

  Future<void> _stopListening() async {
    _log('stop_begin');
    _stopDebounce?.cancel();
    _stopDebounce = null;
    _routeDebounce?.cancel();
    _routeDebounce = null;
    _snapHeartbeat?.cancel();
    _snapHeartbeat = null;
    await _eventSub?.cancel();
    _eventSub = null;
    if (_listening) {
      try {
        await _methods.invokeMethod<void>('stop');
      } catch (e) {
        _log('stop_native_fail', {'err': '$e'});
      }
    }
    _listening = false;
    _near = false;
    _hasSensor = false;
    _pipelineReady = false;
    _playStartedAt = null;
    try {
      await AudioPlayer.global.setAudioContext(_speakerOnlyContext);
      _log('audio_context', {'kind': 'speakerOnly', 'why': 'stop'});
    } catch (_) {}
    _log('stop_done');
  }

  /// Communication usage + speaker on — earpiece is a speakerphone toggle only.
  static final AudioContext _routableContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
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
        AVAudioSessionOptions.defaultToSpeaker,
      },
    ),
  );

  static final AudioContext _speakerOnlyContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: false,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {},
    ),
  );
}
