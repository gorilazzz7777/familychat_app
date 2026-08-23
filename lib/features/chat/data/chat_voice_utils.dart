bool isVoiceAttachment(
  Map<String, dynamic> attachment, {
  Map<String, dynamic>? messageMetadata,
}) {
  final voiceMeta = messageMetadata?['voice'];
  if (voiceMeta is Map) return true;

  final filename = attachment['filename']?.toString() ?? '';
  final contentType = attachment['content_type']?.toString() ?? '';
  if (filename.startsWith('voice_')) return true;
  if (looksLikeVoiceShare(filename: filename, contentType: contentType)) {
    return true;
  }
  if (contentType.startsWith('audio/')) return true;
  return false;
}

/// Голосовые из Telegram: Opus в `.ogg` / `audio/ogg`.
bool looksLikeVoiceShare({
  String? filename,
  String? contentType,
  List<int>? bytes,
}) {
  final ct = (contentType ?? '').toLowerCase();
  if (ct.contains('ogg') ||
      ct.contains('opus') ||
      ct == 'application/ogg') {
    return true;
  }
  final name = (filename ?? '').toLowerCase();
  if (name.endsWith('.ogg') ||
      name.endsWith('.oga') ||
      name.endsWith('.opus')) {
    return true;
  }
  if (bytes != null &&
      bytes.length >= 4 &&
      bytes[0] == 0x4F &&
      bytes[1] == 0x67 &&
      bytes[2] == 0x67 &&
      bytes[3] == 0x53) {
    return true;
  }
  return false;
}

String voiceFilenameExtension(String filename, {String? contentType}) {
  final name = filename.toLowerCase();
  if (name.endsWith('.opus')) return 'opus';
  if (name.endsWith('.oga')) return 'oga';
  if (name.endsWith('.ogg')) return 'ogg';
  final ct = (contentType ?? '').toLowerCase();
  if (ct.contains('opus') && !ct.contains('ogg')) return 'opus';
  if (ct.contains('ogg')) return 'ogg';
  return 'ogg';
}

int? voiceDurationMsFromMetadata(Map<String, dynamic>? metadata) {
  final voice = metadata?['voice'];
  if (voice is! Map) return null;
  final raw = voice['duration_ms'];
  if (raw is int) return raw;
  return int.tryParse(raw?.toString() ?? '');
}

int? voiceDurationMsForAttachment(
  Map<String, dynamic> attachment, {
  Map<String, dynamic>? messageMetadata,
}) {
  final fromMeta = voiceDurationMsFromMetadata(messageMetadata);
  if (fromMeta != null) return fromMeta;

  final filename = attachment['filename']?.toString() ?? '';
  if (!filename.startsWith('voice_')) return null;
  final stem = filename.split('.').first;
  final raw = stem.replaceFirst('voice_', '');
  return int.tryParse(raw);
}

String formatVoiceDuration(int durationMs) {
  final totalSeconds = (durationMs / 1000).ceil();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes > 0) {
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
  return '0:${seconds.toString().padLeft(2, '0')}';
}

String voiceMessageFilename(int durationMs, {String extension = 'm4a'}) =>
    'voice_$durationMs.$extension';

String voiceExtensionForEncoder(String encoderName) {
  final name = encoderName.toLowerCase();
  if (name.contains('wav')) return 'wav';
  if (name.contains('opus') || name.contains('webm')) return 'webm';
  if (name.contains('ogg')) return 'ogg';
  return 'm4a';
}

String voiceContentTypeForExtension(String extension) {
  return switch (extension) {
    'wav' => 'audio/wav',
    'webm' => 'audio/webm',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'mp3' => 'audio/mpeg',
    _ => 'audio/mp4',
  };
}

/// MIME для плеера: сырой Opus в Ogg лучше отдавать как `audio/ogg`.
String voicePlaybackMimeType({String? filename, String? contentType}) {
  final ct = (contentType ?? '').trim();
  if (ct.isNotEmpty &&
      ct != 'application/octet-stream' &&
      ct != 'application/ogg') {
    if (ct.contains('opus') || ct.contains('ogg')) return 'audio/ogg';
    return ct;
  }
  return voiceContentTypeForExtension(
    voiceFilenameExtension(filename ?? '', contentType: contentType),
  );
}