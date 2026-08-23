/// Альбомы Dairy живут в `littleone-diary/...`, FamilyChat — в `familychat/...`.
/// Фото общие, поэтому «Все фото» уже видит снимки; сами альбомы надо подмешивать.
const kDiaryAlbumIdPrefix = 'diary:';

bool isDiaryAlbumId(String albumId) => albumId.startsWith(kDiaryAlbumIdPrefix);

String toDiaryAlbumId(String albumId) {
  if (albumId.isEmpty || albumId == 'all' || isDiaryAlbumId(albumId)) {
    return albumId;
  }
  return '$kDiaryAlbumIdPrefix$albumId';
}

String fromDiaryAlbumId(String albumId) {
  if (!isDiaryAlbumId(albumId)) return albumId;
  return albumId.substring(kDiaryAlbumIdPrefix.length);
}

List<Map<String, dynamic>> galleryAlbumMapsOf(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

String galleryAlbumKindOf(Map<String, dynamic> album) {
  final kind = album['kind']?.toString() ?? '';
  if (kind == 'all' ||
      kind == 'custom' ||
      kind == 'face' ||
      kind == 'place' ||
      kind == 'year') {
    return kind;
  }
  if (kind == 'diary' || kind == 'dairy' || kind == 'littleone') {
    return 'custom';
  }
  final id = album['id']?.toString() ?? '';
  if (id == 'all') return 'all';
  if (id.startsWith('custom:') || isDiaryAlbumId(id)) return 'custom';
  return kind.isEmpty ? 'custom' : kind;
}

/// FamilyChat-список + custom-альбомы Dairy (id с префиксом `diary:`).
List<Map<String, dynamic>> mergeDiaryCustomAlbums({
  required List<Map<String, dynamic>> familychatAlbums,
  required List<Map<String, dynamic>> diaryAlbums,
}) {
  final out = [
    for (final album in familychatAlbums) Map<String, dynamic>.from(album),
  ];
  final existingIds = <String>{
    for (final album in out) album['id']?.toString() ?? '',
  }..remove('');
  final existingTitles = <String>{
    for (final album in out)
      if (galleryAlbumKindOf(album) == 'custom')
        (album['title']?.toString() ?? '').trim().toLowerCase(),
  }..remove('');

  for (final raw in diaryAlbums) {
    final album = Map<String, dynamic>.from(raw);
    if (galleryAlbumKindOf(album) != 'custom') continue;
    final id = album['id']?.toString() ?? '';
    if (id.isEmpty || id == 'all') continue;
    final bridgedId = toDiaryAlbumId(id);
    if (existingIds.contains(id) || existingIds.contains(bridgedId)) continue;
    final title = (album['title']?.toString() ?? '').trim().toLowerCase();
    if (title.isNotEmpty && existingTitles.contains(title)) continue;
    album['id'] = bridgedId;
    album['kind'] = 'custom';
    album['source'] = 'diary';
    out.add(album);
    existingIds.add(bridgedId);
    if (title.isNotEmpty) existingTitles.add(title);
  }
  return out;
}
