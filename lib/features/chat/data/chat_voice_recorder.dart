import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'chat_voice_recording_bytes.dart';

class ChatVoiceRecorder {
  ChatVoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  String? _path;
  DateTime? _startedAt;
  AudioEncoder? _encoder;

  bool get isActive => _startedAt != null;

  AudioEncoder get encoder =>
      _encoder ?? (kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc);

  Future<bool> ensurePermission() async {
    if (await _recorder.hasPermission()) return true;
    if (kIsWeb) {
      // Browser prompts via getUserMedia inside hasPermission/start.
      return await _recorder.hasPermission();
    }
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> start() async {
    if (isActive) return;
    final preferred =
        kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc;
    final supported = await _recorder.isEncoderSupported(preferred);
    final encoder = supported
        ? preferred
        : (kIsWeb ? AudioEncoder.wav : AudioEncoder.aacLc);
    _encoder = encoder;

    // На web path формально обязателен, но платформа его не использует
    // (результат — blob URL из stop()).
    final path = await voiceRecordingTempPath() ??
        'voice_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _recorder.start(RecordConfig(encoder: encoder), path: path);
    _path = path;
    _startedAt = DateTime.now();
  }

  Future<({Uint8List bytes, int durationMs, AudioEncoder encoder})?>
      stop() async {
    if (!isActive) return null;

    final startedAt = _startedAt!;
    final recordedPath = _path;
    final usedEncoder = encoder;
    _startedAt = null;
    _path = null;

    final stoppedPath = await _recorder.stop();
    final path = stoppedPath ?? recordedPath;
    if (path == null) return null;

    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    final bytes = await readVoiceRecordingBytes(path);
    if (bytes == null || bytes.isEmpty) return null;
    return (bytes: bytes, durationMs: durationMs, encoder: usedEncoder);
  }

  Future<void> cancel() async {
    if (!isActive) {
      try {
        await _recorder.stop();
      } catch (_) {}
      return;
    }

    final recordedPath = _path;
    _startedAt = null;
    _path = null;

    final stoppedPath = await _recorder.stop();
    final path = stoppedPath ?? recordedPath;
    if (path != null) {
      await discardVoiceRecordingFile(path);
    }
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
