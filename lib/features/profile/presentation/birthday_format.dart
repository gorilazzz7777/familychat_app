String formatBirthDateForApi(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Парсит дату в формате ДД.ММ.ГГГГ (или только цифры).
DateTime? parseDdMmYyyy(String text) {
  final digits = text.replaceAll(RegExp(r'\D'), '');
  if (digits.length != 8) return null;

  final day = int.tryParse(digits.substring(0, 2));
  final month = int.tryParse(digits.substring(2, 4));
  final year = int.tryParse(digits.substring(4, 8));
  if (day == null || month == null || year == null) return null;
  if (month < 1 || month > 12 || day < 1 || year < 1900 || year > 2100) {
    return null;
  }

  try {
    final d = DateTime(year, month, day);
    if (d.year != year || d.month != month || d.day != day) return null;
    return d;
  } catch (_) {
    return null;
  }
}

DateTime? parseBirthDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.trim();
  if (text.contains('.')) {
    return parseDdMmYyyy(text);
  }
  final datePart = text.contains('T') ? text.split('T').first : text;
  final parts = datePart.split('-');
  if (parts.length != 3) return DateTime.tryParse(text);
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return DateTime(year, month, day);
}

String formatBirthDateDisplay(DateTime date, {required bool showYear}) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  if (showYear) {
    return '$day.$month.${date.year}';
  }
  return '$day.$month';
}
