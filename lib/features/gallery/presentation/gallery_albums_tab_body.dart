/// Shared helpers for family / profile / child gallery album tabs.
String galleryAlbumsFingerprint(List<Map<String, dynamic>> albums) {
  return albums
      .map((a) {
        final cover = a['cover'];
        final coverId = a['cover_attachment_id'] ??
            (cover is Map ? cover['id'] : null);
        final count = a['count'] ?? a['photos_count'];
        return '${a['id']}|${a['title']}|$coverId|$count|${a['kind']}';
      })
      .join(';');
}

List<Map<String, dynamic>> galleryAlbumsAsMaps(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}
