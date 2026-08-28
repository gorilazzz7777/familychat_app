import '../../../core/media/gallery_media_utils.dart';
import 'chat_realtime_utils.dart';
import 'chat_voice_utils.dart';

/// Текст превью сообщения для списка чатов / поиска / цитат.
///
/// Пустой `body` у медиа не должен превращаться в безликое «Сообщение».
String chatMessagePreviewText(Map<String, dynamic>? message) {
  if (message == null) return 'Нет сообщений';

  if (message['is_system'] == true) {
    final systemBody = message['body']?.toString().trim() ?? '';
    return systemBody.isNotEmpty ? systemBody : 'Системное сообщение';
  }

  final body = message['body']?.toString().trim() ?? '';
  if (body.isNotEmpty) return body;

  final metadata = message['metadata'];
  final meta = metadata is Map
      ? metadata.map((key, value) => MapEntry(key.toString(), value))
      : const <String, dynamic>{};

  if (meta['voice'] is Map) return 'Голосовое сообщение';
  if (meta['location'] is Map) return 'Геолокация';
  if (meta['video_note'] is Map) return 'Видеосообщение';
  if (meta['sticker'] != null) return 'Стикер';
  if (meta['gif'] != null) return 'GIF';

  final atts = chatAttachmentsOf(message);
  if (atts.isEmpty) return 'Сообщение';

  var images = 0;
  var videos = 0;
  var voices = 0;
  var videoNotes = 0;
  var files = 0;
  String? firstFileName;

  for (final att in atts) {
    if (att['is_video_note'] == true || att['is_video_note'] == 'true') {
      videoNotes += 1;
      continue;
    }
    if (isVoiceAttachment(att, messageMetadata: meta)) {
      voices += 1;
      continue;
    }
    if (isVideoAttachment(att)) {
      videos += 1;
      continue;
    }
    if (isImageAttachment(att)) {
      images += 1;
      continue;
    }
    files += 1;
    firstFileName ??= att['filename']?.toString().trim();
  }

  if (videoNotes > 0 && images + videos + voices + files == 0) {
    return 'Видеосообщение';
  }
  if (voices > 0 && images + videos + files == 0) {
    return 'Голосовое сообщение';
  }
  if (images > 0 && videos == 0 && files == 0) {
    return images > 1 ? 'Фото ($images)' : 'Фото';
  }
  if (videos > 0 && images == 0 && files == 0) {
    return videos > 1 ? 'Видео ($videos)' : 'Видео';
  }
  if (images + videos > 0) return 'Медиа';
  if (files == 1) {
    final name = firstFileName ?? '';
    return name.isNotEmpty ? name : 'Файл';
  }
  if (files > 1) return 'Файлы ($files)';
  return 'Вложение';
}

/// Hub `last_message` often omits attachments; keep the richer local copy.
Map<String, dynamic> chatPreferRicherLastMessage(
  Map<String, dynamic>? server,
  Map<String, dynamic>? local,
) {
  if (server == null) return local ?? const <String, dynamic>{};
  if (local == null) return server;

  final serverId = chatAsInt(server['id']);
  final localId = chatAsInt(local['id']);
  if (serverId == null || localId == null || serverId != localId) {
    return server;
  }

  final merged = Map<String, dynamic>.from(server);
  final serverAtts = server['attachments'];
  final localAtts = local['attachments'];
  final serverHasAtts = serverAtts is List && serverAtts.isNotEmpty;
  final localHasAtts = localAtts is List && localAtts.isNotEmpty;
  if (!serverHasAtts && localHasAtts) {
    merged['attachments'] = localAtts;
  }

  final serverMeta = server['metadata'];
  final localMeta = local['metadata'];
  final serverMetaEmpty = serverMeta is! Map || serverMeta.isEmpty;
  final localMetaUseful = localMeta is Map && localMeta.isNotEmpty;
  if (serverMetaEmpty && localMetaUseful) {
    merged['metadata'] = localMeta;
  }

  final serverBody = server['body']?.toString().trim() ?? '';
  final localBody = local['body']?.toString().trim() ?? '';
  if (serverBody.isEmpty && localBody.isNotEmpty) {
    merged['body'] = local['body'];
  }

  return merged;
}

bool chatLastMessageLacksPreviewPayload(Map<String, dynamic> message) {
  final body = message['body']?.toString().trim() ?? '';
  if (body.isNotEmpty) return false;
  final atts = message['attachments'];
  if (atts is List && atts.isNotEmpty) return false;
  final meta = message['metadata'];
  if (meta is Map) {
    if (meta['voice'] is Map ||
        meta['location'] is Map ||
        meta['video_note'] is Map ||
        meta['sticker'] != null ||
        meta['gif'] != null) {
      return false;
    }
  }
  return true;
}
