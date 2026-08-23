/// Элемент каталога GIF с бэкенда (Klipy proxy).
class ChatGifItem {
  const ChatGifItem({
    required this.id,
    required this.url,
    required this.previewUrl,
    this.slug = '',
    this.title = '',
    this.width = 0,
    this.height = 0,
    this.contentType = 'image/gif',
  });

  final String id;
  final String slug;
  final String title;
  final String url;
  final String previewUrl;
  final int width;
  final int height;
  final String contentType;

  factory ChatGifItem.fromJson(Map<String, dynamic> json) {
    return ChatGifItem(
      id: json['id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      previewUrl: (json['preview_url'] ?? json['url'])?.toString() ?? '',
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      contentType: json['content_type']?.toString() ?? 'image/gif',
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
