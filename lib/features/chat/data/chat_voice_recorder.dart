import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class ChatVoiceRecorder {
  ChatVoiceRecorder() : _recorder = AudioRecorder();

  final AudioRecorder _recorder;
  String? _path;
  DateTime? _startedAt;

  bool get isActive => _startedAt != null;

  Future<bool> ensurePermission() async {
    if (await _recorder.hasPermission()) return true;
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<void> start() async {
    if (isActive) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _path = path;
    _startedAt = DateTime.now();
  }

  Future<({Uint8List bytes, int durationMs})?> stop() async {
    if (!isActive) return null;

    final startedAt = _startedAt!;
    final recordedPath = _path;
    _startedAt = null;
    _path = null;

    final stoppedPath = await _recorder.stop();
    final path = stoppedPath ?? recordedPath;
    if (path == null) return null;

    final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    await file.delete();
    if (bytes.isEmpty) return null;
    return (bytes: bytes, durationMs: durationMs);
  }

  Future<void> cancel() async {
    if (!isActive) {
      await _recorder.stop();
      return;
    }

    final recordedPath = _path;
    _startedAt = null;
    _path = null;

    final stoppedPath = await _recorder.stop();
    final path = stoppedPath ?? recordedPath;
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
