bool isVoiceAttachment(
  Map<String, dynamic> attachment, {
  Map<String, dynamic>? messageMetadata,
}) {
  final voiceMeta = messageMetadata?['voice'];
  if (voiceMeta is Map) return true;

  final filename = attachment['filename']?.toString() ?? '';
  final contentType = attachment['content_type']?.toString() ?? '';
  return filename.startsWith('voice_') && contentType.startsWith('audio/');
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

String voiceMessageFilename(int durationMs) => 'voice_$durationMs.m4a';
