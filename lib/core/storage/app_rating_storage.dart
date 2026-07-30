import 'package:shared_preferences/shared_preferences.dart';

/// Локально сохранённая оценка приложения (после успешной отправки на сервер).
abstract final class AppRatingStorage {
  static const String starsKey = 'familychat_app_rating_stars_v1';
  static const String submittedAtMsKey =
      'familychat_app_rating_submitted_at_ms_v1';

  static Future<void> saveSubmitted(int stars) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(starsKey, stars);
    await prefs.setInt(
      submittedAtMsKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<int?> submittedStars() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(starsKey);
  }
}