/// Элемент каталога GIF/стикеров с бэкенда (Klipy proxy).
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
    this.kind = 'gif',
  });

  final String id;
  final String slug;
  final String title;
  final String url;
  final String previewUrl;
  final int width;
  final int height;
  final String contentType;
  /// `gif` or `sticker`.
  final String kind;

  bool get isSticker => kind == 'sticker';

  /// URL для превью в сетке (mp4/webm → fallback на полный файл).
  String get gridPreviewUrl {
    bool isVideo(String u) {
      final lower = u.toLowerCase();
      return lower.contains('.mp4') || lower.contains('.webm');
    }

    if (!isVideo(previewUrl)) return previewUrl;
    if (!isVideo(url)) return url;
    return previewUrl;
  }

  factory ChatGifItem.fromJson(Map<String, dynamic> json) {
    final kind = json['kind']?.toString() ?? 'gif';
    return ChatGifItem(
      id: json['id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      previewUrl: (json['preview_url'] ?? json['url'])?.toString() ?? '',
      width: _asInt(json['width']),
      height: _asInt(json['height']),
      contentType: json['content_type']?.toString() ??
          (kind == 'sticker' ? 'image/webp' : 'image/gif'),
      kind: kind,
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}
