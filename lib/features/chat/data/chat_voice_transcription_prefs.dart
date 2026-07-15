import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_voice_transcription.dart';

const _kPreferTextKey = 'familychat_voice_prefer_text';

/// Глобальный режим отображения голосовых: текст vs плеер (для Premium).
final voiceMessagePreferTextProvider =
    StateNotifierProvider<VoiceMessagePreferTextController, bool>((ref) {
  return VoiceMessagePreferTextController();
});

class VoiceMessagePreferTextController extends StateNotifier<bool> {
  VoiceMessagePreferTextController() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kPreferTextKey) ?? false;
  }

  Future<void> setPreferText(bool value) async {
    if (state == value) return;
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPreferTextKey, value);
  }

  Future<void> toggle() => setPreferText(!state);
}

/// Фоновое распаковывание модели Vosk при старте (без сети).
final voskModelPreloadProvider = FutureProvider<void>((ref) async {
  await ChatVoiceTranscription.instance.preloadModelToDisk();
});
