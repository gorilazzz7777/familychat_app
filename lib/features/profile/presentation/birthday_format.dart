String formatBirthDateForApi(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

DateTime? parseBirthDate(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final text = raw.trim();
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
