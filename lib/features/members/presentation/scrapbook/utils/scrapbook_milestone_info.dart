import 'package:intl/intl.dart';

import '../../../../profile/presentation/birthday_format.dart';
import 'baby_age_format.dart';

DateTime? scrapbookMilestoneAchievedDate(Map<String, dynamic> milestone) {
  return parseBirthDate(milestone['achieved_at']?.toString()) ??
      parseBirthDate(milestone['achieved_at_display']?.toString());
}

String? scrapbookMilestoneAchievedDateLabel(Map<String, dynamic> milestone) {
  final display = milestone['achieved_at_display']?.toString().trim();
  if (display != null && display.isNotEmpty) return display;

  final achievedAt = scrapbookMilestoneAchievedDate(milestone);
  if (achievedAt == null) return null;
  return DateFormat('d MMMM yyyy', 'ru').format(achievedAt);
}

String? scrapbookMilestoneAgeLabel({
  required Map<String, dynamic> milestone,
  required DateTime? birthDate,
}) {
  if (birthDate == null) return null;
  final achievedAt = scrapbookMilestoneAchievedDate(milestone);
  if (achievedAt == null) return null;
  final age = babyAgeAtDate(birthDate: birthDate, onDate: achievedAt);
  return age.isEmpty ? null : age;
}
