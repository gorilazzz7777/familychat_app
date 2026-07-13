import 'package:intl/intl.dart';

String formatFeedEventDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;

  if (diff == 0) {
    return DateFormat('HH:mm', 'ru').format(local);
  }
  if (diff == 1) {
    return 'вчера';
  }
  if (local.year == now.year) {
    return DateFormat('d MMM.', 'ru').format(local);
  }
  return DateFormat('d MMM. yyyy', 'ru').format(local);
}
