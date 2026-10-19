import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// SaluteSpeech / SmartSpeech bot used for TG voice → text.
abstract final class TdlibSmartSpeech {
  static const botUsername = 'smartspeech_sber_bot';
  static const consentPrefKey = 'tdlib_smartspeech_consent_v1';
  static const transcriptsPrefKey = 'tdlib_voice_transcripts_v1';

  static String transcriptKey(int chatId, int messageId) =>
      '$chatId:$messageId';

  static Future<bool> hasConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(consentPrefKey) ?? false;
  }

  static Future<void> setConsent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(consentPrefKey, value);
  }

  static Future<Map<String, String>> loadTranscripts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(transcriptsPrefKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, String>{};
      var dropped = false;
      for (final e in decoded.entries) {
        final text = e.value?.toString().trim() ?? '';
        if (text.isEmpty) continue;
        // Drop poisoned status-ack cache (SessionLog 09:13 / UI 13:13).
        if (isStatusAck(text) || isBotSystemBlurb(text)) {
          dropped = true;
          continue;
        }
        out[e.key.toString()] = text;
      }
      if (dropped) {
        await prefs.setString(transcriptsPrefKey, jsonEncode(out));
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveTranscripts(Map<String, String> map) async {
    final prefs = await SharedPreferences.getInstance();
    // Cap growth — keep newest ~400 entries.
    final entries = map.entries.toList();
    if (entries.length > 400) {
      final trimmed = Map<String, String>.fromEntries(
        entries.sublist(entries.length - 400),
      );
      await prefs.setString(transcriptsPrefKey, jsonEncode(trimmed));
      return;
    }
    await prefs.setString(transcriptsPrefKey, jsonEncode(map));
  }

  /// SaluteSpeech progress / ack lines — not the transcript body.
  ///
  /// SessionLog 09:13 / UI 13:13: first bot reply «Аудиосообщение принято!»
  /// (chars=23); real text arrives later (often as edit of the same msg).
  static bool isStatusAck(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return true;
    // Strip emoji / zero-width for matching.
    final lower = t
        .toLowerCase()
        .replaceAll(RegExp(r'[\u200b-\u200d\ufeff]'), '')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (lower.contains('аудиосообщение принято')) return true;
    if (lower.contains('сообщение принято')) return true;
    if (lower.contains('message accepted')) return true;
    if (lower.contains('аудио принято')) return true;
    if (lower.contains('файл принят')) return true;
    if (lower.contains('голосовое принято')) return true;
    if (RegExp(
      r'^(⏳|✅|✔️|✓|✔)?\s*(распознаю|обрабатываю|подождите|секунду|loading|готово[!.,]?)',
      caseSensitive: false,
    ).hasMatch(t)) {
      return true;
    }
    // Short non-sentence acks only.
    if (t.length <= 48 &&
        RegExp(
          r'^(ok|принято|принято[!.,]?|done|принято\s*)$',
          caseSensitive: false,
        ).hasMatch(lower)) {
      return true;
    }
    return false;
  }

  /// /start welcome and other bot chrome — never show as a voice transcript.
  static bool isBotSystemBlurb(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return true;
    final lower = t.toLowerCase();
    if (isStatusAck(t)) return true;
    // Typical SaluteSpeech /start / help blurbs.
    if (lower.contains('salutespeech')) return true;
    if (lower.contains('smartspeech')) return true;
    if (lower.contains('/start')) return true;
    if (lower.contains('/help')) return true;
    if (lower.contains('/lang')) return true;
    if (lower.contains('перешлите') && lower.contains('голосо')) return true;
    if (lower.contains('отправьте') && lower.contains('голосо')) return true;
    if (lower.contains('я бот') || lower.contains('этот бот')) return true;
    return false;
  }

  /// Strip obvious bot chrome; keep the recognition body.
  /// Returns empty when [raw] is only a status ack / system blurb.
  static String cleanReplyText(String raw) {
    var text = raw.trim();
    if (text.isEmpty || isStatusAck(text) || isBotSystemBlurb(text)) {
      return '';
    }
    // Drop leading bot status lines that are not the transcript body.
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) => l.isNotEmpty && !isStatusAck(l) && !isBotSystemBlurb(l),
        )
        .toList();
    if (lines.isEmpty) return '';
    // Multi-line: also drop short UI/status prefixes.
    final skip = RegExp(
      r'^(распозна|обработ|подожд|секун|loading|error|ошибк)',
      caseSensitive: false,
    );
    final kept = lines.where((l) => !skip.hasMatch(l)).toList();
    final body = (kept.isEmpty ? lines : kept).join('\n').trim();
    if (body.isEmpty || isStatusAck(body) || isBotSystemBlurb(body)) {
      return '';
    }
    return body;
  }
}

/// Thrown when the user has not accepted the SmartSpeech consent dialog yet.
class TdlibSmartSpeechNeedConsent implements Exception {
  @override
  String toString() => 'TdlibSmartSpeechNeedConsent';
}
