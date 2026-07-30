import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/app_providers.dart';

const _prefsKey = 'familychat_share_to_diary_v1';

class ShareToDiaryPrefs extends StateNotifier<bool> {
  ShareToDiaryPrefs() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_prefsKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
  }
}

final shareToDiaryPrefsProvider =
    StateNotifierProvider<ShareToDiaryPrefs, bool>((ref) {
  return ShareToDiaryPrefs();
});

final diaryShareAvailableProvider = FutureProvider<bool>((ref) async {
  final repo = ref.watch(familychatRepositoryProvider);
  try {
    final data = await repo.diaryShareStatus();
    return data['available'] == true;
  } catch (_) {
    return false;
  }
});
