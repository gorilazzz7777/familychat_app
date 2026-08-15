/// Возраст малыша на конкретную дату (для подписей в альбоме).
String babyAgeAtDate({
  required DateTime birthDate,
  required DateTime onDate,
}) {
  if (onDate.isBefore(birthDate)) return '';

  var years = onDate.year - birthDate.year;
  var months = onDate.month - birthDate.month;
  var days = onDate.day - birthDate.day;

  if (days < 0) {
    months -= 1;
  }
  if (months < 0) {
    years -= 1;
    months += 12;
  }

  if (years <= 0 && months <= 0) {
    final totalDays = onDate.difference(birthDate).inDays;
    if (totalDays <= 0) return 'новорождённый';
    return _pluralDays(totalDays);
  }

  if (years <= 0) {
    return _pluralMonths(months);
  }

  if (months == 0) {
    return _pluralYears(years);
  }

  return '${_pluralYears(years)} ${_pluralMonths(months)}';
}

/// Подпись для виджета: «Нам 3 месяца, 2 недели и 5 дней».
///
/// До недели — только дни; до месяца — недели и дни;
/// дальше — месяцы (и годы) + недели + дни.
String babyAgeNamLabel({
  required DateTime birthDate,
  DateTime? onDate,
}) {
  final birth = DateTime(birthDate.year, birthDate.month, birthDate.day);
  final on = onDate ?? DateTime.now();
  final today = DateTime(on.year, on.month, on.day);
  if (today.isBefore(birth)) return '';

  final totalDays = today.difference(birth).inDays;
  if (totalDays <= 0) return 'Нам сегодня';

  var years = today.year - birth.year;
  var months = today.month - birth.month;
  var dayRem = today.day - birth.day;
  if (dayRem < 0) {
    months -= 1;
    final prevMonthLastDay = DateTime(today.year, today.month, 0).day;
    dayRem += prevMonthLastDay;
  }
  if (months < 0) {
    years -= 1;
    months += 12;
  }

  // До полного месяца — дни / недели.
  if (years == 0 && months == 0) {
    if (totalDays < 7) {
      return 'Нам ${_pluralDays(totalDays)}';
    }
    final weeks = totalDays ~/ 7;
    final days = totalDays % 7;
    return 'Нам ${_joinAgeParts([
      _pluralWeeks(weeks),
      if (days > 0) _pluralDays(days),
    ])}';
  }

  final parts = <String>[
    if (years > 0) _pluralYears(years),
    if (months > 0) _pluralMonths(months),
  ];
  final weeks = dayRem ~/ 7;
  final days = dayRem % 7;
  if (weeks > 0) parts.add(_pluralWeeks(weeks));
  if (days > 0) parts.add(_pluralDays(days));
  if (parts.isEmpty) return 'Нам ${_pluralMonths(0)}';
  return 'Нам ${_joinAgeParts(parts)}';
}

String _joinAgeParts(List<String> parts) {
  if (parts.isEmpty) return '';
  if (parts.length == 1) return parts.first;
  if (parts.length == 2) return '${parts[0]} и ${parts[1]}';
  return '${parts.sublist(0, parts.length - 1).join(', ')} и ${parts.last}';
}

String _pluralWeeks(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return '$n неделя';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$n недели';
  }
  return '$n недель';
}

String _pluralDays(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return '$n день';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$n дня';
  }
  return '$n дней';
}

String _pluralMonths(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return '$n месяц';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$n месяца';
  }
  return '$n месяцев';
}

String _pluralYears(int n) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return '$n год';
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return '$n года';
  }
  return '$n лет';
}
