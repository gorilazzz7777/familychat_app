import 'dart:html' as html;
import 'dart:typed_data';

Future<Uint8List?> readVoiceRecordingBytes(String path) async {
  try {
    final request = await html.HttpRequest.request(
      path,
      responseType: 'arraybuffer',
    );
    final buffer = request.response;
    if (buffer is! ByteBuffer) return null;
    final bytes = buffer.asUint8List();
    html.Url.revokeObjectUrl(path);
    if (bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    try {
      html.Url.revokeObjectUrl(path);
    } catch (_) {}
    return null;
  }
}

Future<void> discardVoiceRecordingFile(String path) async {
  try {
    html.Url.revokeObjectUrl(path);
  } catch (_) {}
}

Future<String?> voiceRecordingTempPath() async => null;
