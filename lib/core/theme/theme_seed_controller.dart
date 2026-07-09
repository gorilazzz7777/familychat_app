import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/app_providers.dart';
import 'app_theme.dart';

const _prefsKey = 'familychat_theme_seed_color';

final themeSeedProvider =
    StateNotifierProvider<ThemeSeedController, Color>((ref) {
  return ThemeSeedController(ref);
});

class ThemeSeedController extends StateNotifier<Color> {
  ThemeSeedController(this._ref) : super(AppTheme.defaultSeedColor) {
    unawaited(_loadCached());
  }

  final Ref _ref;

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      state = AppTheme.parseSeedColor(raw);
    } catch (_) {}
  }

  Future<void> _cache(Color color) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, AppTheme.colorToHex(color));
    } catch (_) {}
  }

  Future<void> syncFromStatus(Map<String, dynamic>? status) async {
    if (status == null) return;
    final color = AppTheme.parseSeedColor(status['theme_seed_color']?.toString());
    state = color;
    await _cache(color);
  }

  Future<void> applyAndSave(Color seedColor) async {
    final normalized = AppTheme.normalizeSeedColor(seedColor);
    state = normalized;
    await _cache(normalized);
    try {
      await _ref.read(familychatRepositoryProvider).updateProfile(
            themeSeedColor: AppTheme.colorToHex(normalized),
          );
    } catch (_) {
      rethrow;
    }
  }

  Future<void> resetToDefault() async {
    state = AppTheme.defaultSeedColor;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}
