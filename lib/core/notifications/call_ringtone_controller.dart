import 'package:flutter/foundation.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import 'call_ringtone_web_stub.dart'
    if (dart.library.html) 'call_ringtone_web.dart';

/// Звонок, когда приложение открыто (WebSocket / push без системного баннера).
class CallRingtoneController {
  CallRingtoneController._();

  static final CallRingtoneController instance = CallRingtoneController._();

  bool _playing = false;

  Future<void> startIncomingCall() async {
    if (_playing) return;
    _playing = true;
    if (kIsWeb) {
      try {
        await startWebCallRingtone();
      } catch (e) {
        debugPrint('web incoming call ringtone failed: $e');
        _playing = false;
      }
      return;
    }
    try {
      await FlutterRingtonePlayer().playRingtone(
        volume: 1.0,
        looping: true,
      );
    } catch (e) {
      debugPrint('incoming call ringtone failed: $e');
      _playing = false;
    }
  }

  Future<void> stop() async {
    if (!_playing) return;
    _playing = false;
    if (kIsWeb) {
      stopWebCallRingtone();
      return;
    }
    try {
      await FlutterRingtonePlayer().stop();
    } catch (e) {
      debugPrint('stop ringtone failed: $e');
    }
  }
}
