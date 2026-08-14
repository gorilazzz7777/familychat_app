import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'app_settings.dart';
import 'app_settings_storage.dart';

final appSettingsProvider =
    StateNotifierProvider<AppSettingsController, FamilyChatAppSettings>((ref) {
  return AppSettingsController(ref);
});

class AppSettingsController extends StateNotifier<FamilyChatAppSettings> {
  AppSettingsController(this._ref) : super(const FamilyChatAppSettings()) {
    unawaited(_load());
  }

  final Ref _ref;
  bool _syncing = false;

  Future<void> _load() async {
    final local = await AppSettingsStorage.load();
    if (!mounted) return;
    state = local;
    await syncFromServer();
  }

  Future<void> syncFromServer() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final remote =
          await _ref.read(familychatRepositoryProvider).fetchAppSettings();
      if (!mounted) return;
      state = remote;
      await AppSettingsStorage.save(remote);
    } catch (_) {
    } finally {
      _syncing = false;
    }
  }

  Future<void> update(FamilyChatAppSettings next) async {
    final previous = state;
    state = next;
    await AppSettingsStorage.save(next);
    try {
      final saved =
          await _ref.read(familychatRepositoryProvider).updateAppSettings(next);
      if (!mounted) return;
      state = saved;
      await AppSettingsStorage.save(saved);
    } catch (e) {
      if (mounted) state = previous;
      await AppSettingsStorage.save(previous);
      rethrow;
    }
  }

  Future<void> resetToDefaults() async {
    state = const FamilyChatAppSettings();
    await AppSettingsStorage.save(state);
  }
}
