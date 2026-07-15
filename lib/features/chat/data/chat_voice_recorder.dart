import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'chat_voice_recording_bytes.dart';

/// 16 kHz — совместимо с Vosk small-ru.
const int kChatVoiceTranscriptionSampleRate = 16000;

class ChatVoiceRecorder {
  ChatVoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  String? _path;
  DateTime? _startedAt;
  AudioEncoder? _encoder;
  bool _wavForTranscription = false;

  bool get isActive => _startedAt != null;

  AudioEncoder get encoder =>
      _encoder ??
      (kIsWeb || _wavForTranscription ? AudioEncoder.wav : AudioEncoder.aacLc);

  Future<bool> ensurePermission() async {
    if (await _recorder.hasPermission()) return true;
    if (kIsWeb) {
      return await _recorder.hasPermission();
    }
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> start({bool forTranscription = false}) async {
    if (isActive) return;
    // Web всегда WAV; при STT на native — WAV 16 kHz mono под Vosk.
    final useWav = kIsWeb || forTranscription;
    _wavForTranscription = useWav;
    final preferred = useWav ? AudioEncoder.wav : AudioEncoder.aacLc;
    final supported = await _recorder.isEncoderSupported(preferred);
    final encoder = supported ? preferred : AudioEncoder.wav;
    _encoder = encoder;
    _wavForTranscription = encoder == AudioEncoder.wav;

    final path = await voiceRecordingTempPath() ??
        'voice_${DateTime.now().millisecondsSinceEpoch}.${_wavForTranscription ? 'wav' : 'm4a'}';
    final config = _wavForTranscription
        ? RecordConfig(
            encoder: encoder,
            sampleRate: kChatVoiceTranscriptionSampleRate,
            numChannels: 1,
          )
        : RecordConfig(encoder: encoder);
    await _recorder.start(config, path: path);
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
