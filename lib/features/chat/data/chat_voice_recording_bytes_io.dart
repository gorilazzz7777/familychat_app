import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Uint8List?> readVoiceRecordingBytes(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  try {
    await file.delete();
  } catch (_) {}
  if (bytes.isEmpty) return null;
  return bytes;
}

Future<void> discardVoiceRecordingFile(String path) async {
  final file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
}

Future<String?> voiceRecordingTempPath({String extension = 'm4a'}) async {
  final dir = await getTemporaryDirectory();
  final safeExt = extension.replaceAll(RegExp(r'[^\w]+'), '');
  final ext = safeExt.isEmpty ? 'm4a' : safeExt;
  return '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
}
