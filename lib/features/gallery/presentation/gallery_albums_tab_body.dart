/// Shared helpers for family / profile / child gallery album tabs.
String galleryAlbumsFingerprint(List<Map<String, dynamic>> albums) {
  return albums
      .map((a) =>
          '${a['id']}|${a['title']}|${a['cover_attachment_id']}|${a['photos_count']}|${a['kind']}')
      .join(';');
}

List<Map<String, dynamic>> galleryAlbumsAsMaps(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}
