import 'package:intl/intl.dart';

/// Время/дата последнего сообщения в списке чатов.
String formatChatHubLastMessageTime(DateTime dateTime, {DateTime? now}) {
  final local = dateTime.toLocal();
  final current = now?.toLocal() ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;

  if (diffDays == 0) {
    return DateFormat('HH:mm').format(local);
  }
  if (diffDays >= 1 && diffDays <= 7) {
    return _weekdayShort[local.weekday] ?? DateFormat('E', 'ru').format(local);
  }
  if (local.year == current.year) {
    final month = _monthShort[local.month] ?? '';
    return '${local.day} $month';
  }
  return DateFormat('dd.MM.yyyy').format(local);
}

const _weekdayShort = <int, String>{
  DateTime.monday: 'пн',
  DateTime.tuesday: 'вт',
  DateTime.wednesday: 'ср',
  DateTime.thursday: 'чт',
  DateTime.friday: 'пт',
  DateTime.saturday: 'сб',
  DateTime.sunday: 'вс',
};

const _monthShort = <int, String>{
  1: 'янв.',
  2: 'февр.',
  3: 'мар.',
  4: 'апр.',
  5: 'мая',
  6: 'июня',
  7: 'июля',
  8: 'авг.',
  9: 'сент.',
  10: 'окт.',
  11: 'нояб.',
  12: 'дек.',
};
