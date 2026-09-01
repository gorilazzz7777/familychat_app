import '../../../core/local_db/chat_local_store.dart';
import '../../../core/media/gallery_media_utils.dart';
import 'chat_realtime_utils.dart';
import 'chat_voice_utils.dart';

int? _attachmentCountHint(Map<String, dynamic> message) {
  final count = chatAsInt(message['attachment_count']);
  if (count != null && count > 0) return count;
  if (message['has_attachments'] == true) return 1;
  return null;
}

String _genericMediaPreviewLabel(int count) {
  return count > 1 ? 'Медиа ($count)' : 'Медиа';
}

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
  if (atts.isEmpty) {
    final hint = _attachmentCountHint(message);
    if (hint != null) return _genericMediaPreviewLabel(hint);
    return 'Сообщение';
  }

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
  return _genericMediaPreviewLabel(atts.length);
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
  if (!serverHasAtts) {
    if (local['has_attachments'] == true) {
      merged['has_attachments'] = true;
    }
    final localCount = chatAsInt(local['attachment_count']);
    final serverCount = chatAsInt(server['attachment_count']);
    if (localCount != null && (serverCount == null || localCount > serverCount)) {
      merged['attachment_count'] = localCount;
    }
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

  final mergedStatus = chatMergeReadStatus(
    server['read_status']?.toString(),
    local['read_status']?.toString(),
  );
  if (mergedStatus != null) {
    merged['read_status'] = mergedStatus;
  }

  return merged;
}

/// Hub `last_message` may be slim; pull full payload from local messages when possible.
Future<List<Map<String, dynamic>>> enrichChatThreadsLastMessages(
  List<Map<String, dynamic>> threads,
) async {
  if (!ChatLocalStore.isSupported || threads.isEmpty) return threads;
  final out = <Map<String, dynamic>>[];
  for (final thread in threads) {
    final threadId = chatAsInt(thread['id']);
    final last = thread['last_message'];
    if (threadId == null || last is! Map) {
      out.add(thread);
      continue;
    }
    final lastMap = Map<String, dynamic>.from(last);
    if (!chatLastMessageLacksPreviewPayload(lastMap)) {
      out.add(thread);
      continue;
    }
    final messageId = chatAsInt(lastMap['id']);
    if (messageId == null || messageId <= 0) {
      out.add(thread);
      continue;
    }
    final local = await ChatLocalStore.instance.readMessage(threadId, messageId);
    if (local == null || chatLastMessageLacksPreviewPayload(local)) {
      out.add(thread);
      continue;
    }
    out.add({
      ...thread,
      'last_message': chatPreferRicherLastMessage(lastMap, local),
    });
  }
  return out;
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
