import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class ChatVoiceRecorder {
  ChatVoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  DateTime? _startedAt;

  Future<bool> ensurePermission() async {
    if (await _recorder.hasPermission()) return true;
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _startedAt = DateTime.now();
  }

  Future<({Uint8List bytes, int durationMs})?> stop() async {
    final startedAt = _startedAt;
    final path = await _recorder.stop();
    _startedAt = null;
    if (path == null || startedAt == null) return null;

    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();
    if (bytes.isEmpty) return null;
    return (bytes: bytes, durationMs: durationMs);
  }

  Future<void> cancel() async {
    final path = await _recorder.stop();
    _startedAt = null;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
