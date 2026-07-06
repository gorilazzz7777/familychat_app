/// Нормализация JSON из WebSocket (числа, вложенные map/list).
int? chatAsInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

List<int> chatAsIntList(dynamic value) {
  if (value is! List) return [];
  return value.map(chatAsInt).whereType<int>().toList();
}

Map<String, dynamic> chatNormalizeMap(Map<dynamic, dynamic> map) {
  return map.map(
    (key, value) => MapEntry(key.toString(), chatNormalizeValue(value)),
  );
}

dynamic chatNormalizeValue(dynamic value) {
  if (value is Map) return chatNormalizeMap(Map<dynamic, dynamic>.from(value));
  if (value is List) return value.map(chatNormalizeValue).toList();
  if (value is num && value is! int && value == value.roundToDouble()) {
    return value.toInt();
  }
  return value;
}

List<Map<String, dynamic>> chatAttachmentsOf(Map<String, dynamic> message) {
  final raw = message['attachments'];
  if (raw is! List) return [];
  return raw
      .map((item) {
        if (item is! Map) return null;
        return chatNormalizeMap(Map<dynamic, dynamic>.from(item));
      })
      .whereType<Map<String, dynamic>>()
      .toList();
}
