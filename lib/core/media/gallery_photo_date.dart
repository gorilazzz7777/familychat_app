import 'package:intl/intl.dart';

/// Дата съёмки для группировки альбома: EXIF / taken_at → created_at.
DateTime? galleryPhotoTakenAt(Map<String, dynamic> photo) {
  final exif = photo['photo_exif'];
  if (exif is Map) {
    final fromExif = _parseFlexibleDate(exif['taken_at']?.toString());
    if (fromExif != null) return fromExif;
  }
  final taken = _parseFlexibleDate(photo['taken_at']?.toString());
  if (taken != null) return taken;
  return _parseFlexibleDate(photo['created_at']?.toString());
}

/// Ключ дня `yyyy-MM-dd` (локальная дата).
String galleryPhotoDayKey(DateTime date) {
  final local = date.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String galleryPhotoDayLabel(DateTime date, {DateTime? now}) {
  final local = DateTime(date.year, date.month, date.day);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final yesterday = today.subtract(const Duration(days: 1));
  if (local == today) return 'Сегодня';
  if (local == yesterday) return 'Вчера';
  if (local.year == today.year) {
    return DateFormat('d MMMM', 'ru').format(local);
  }
  return DateFormat('d MMMM yyyy', 'ru').format(local);
}

/// Верхняя дата как в Google Photos: «Пт, 16 сент. 2022 г.»
String galleryPhotoTopDateLabel(DateTime date, {DateTime? now}) {
  final local = DateTime(date.year, date.month, date.day);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final yesterday = today.subtract(const Duration(days: 1));
  if (local == today) return 'Сегодня';
  if (local == yesterday) return 'Вчера';
  final raw = DateFormat('E, d MMM yyyy', 'ru').format(local);
  return '$raw г.';
}

String galleryPhotoMonthLabel(DateTime date) {
  final local = DateTime(date.year, date.month, date.day);
  return DateFormat('LLLL yyyy', 'ru').format(local);
}

/// Подпись у ручки скраббера: «Сент. 2022 г.»
String galleryPhotoScrubMonthLabel(DateTime date) {
  final local = DateTime(date.year, date.month, date.day);
  final raw = DateFormat('MMM yyyy', 'ru').format(local);
  return '$raw г.';
}

DateTime? _parseFlexibleDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final parsed = DateTime.tryParse(raw.trim());
  if (parsed != null) {
    final local = parsed.toLocal();
    return DateTime(local.year, local.month, local.day);
  }
  final parts = raw.split(RegExp(r'[ :\-T]'));
  if (parts.length < 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

class GalleryAlbumDaySection {
  const GalleryAlbumDaySection({
    required this.dayKey,
    required this.date,
    required this.label,
    required this.photos,
  });

  final String dayKey;
  final DateTime date;
  final String label;
  final List<Map<String, dynamic>> photos;

  String get monthLabel => galleryPhotoMonthLabel(date);
}

/// Сортировка по дате съёмки (новые сверху) и группировка по дням.
List<GalleryAlbumDaySection> buildGalleryAlbumDaySections(
  List<Map<String, dynamic>> photos, {
  DateTime? now,
}) {
  if (photos.isEmpty) return const [];

  final sorted = List<Map<String, dynamic>>.from(photos);
  sorted.sort((a, b) {
    final da = galleryPhotoTakenAt(a) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final db = galleryPhotoTakenAt(b) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final byDate = db.compareTo(da);
    if (byDate != 0) return byDate;
    final idA = a['id'] is int ? a['id'] as int : int.tryParse('${a['id']}') ?? 0;
    final idB = b['id'] is int ? b['id'] as int : int.tryParse('${b['id']}') ?? 0;
    return idB.compareTo(idA);
  });

  final sections = <GalleryAlbumDaySection>[];
  String? currentKey;
  DateTime? currentDate;
  var bucket = <Map<String, dynamic>>[];

  void flush() {
    final key = currentKey;
    final date = currentDate;
    if (key == null || date == null || bucket.isEmpty) return;
    sections.add(
      GalleryAlbumDaySection(
        dayKey: key,
        date: date,
        label: galleryPhotoDayLabel(date, now: now),
        photos: List<Map<String, dynamic>>.from(bucket),
      ),
    );
    bucket = [];
  }

  for (final photo in sorted) {
    final date = galleryPhotoTakenAt(photo) ?? DateTime.fromMillisecondsSinceEpoch(0);
    final key = galleryPhotoDayKey(date);
    if (currentKey != key) {
      flush();
      currentKey = key;
      currentDate = DateTime(date.year, date.month, date.day);
    }
    bucket.add(photo);
  }
  flush();
  return sections;
}
