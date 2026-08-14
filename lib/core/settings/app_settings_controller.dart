import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'app_settings.dart';
import 'app_settings_storage.dart';
import 'screen_timeout.dart';

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

  FamilyChatAppSettings _withLocal(
    FamilyChatAppSettings remote,
    FamilyChatAppSettings local,
  ) {
    return remote.copyWith(
      screenTimeout: local.screenTimeout,
      menuOrder: local.menuOrder,
    );
  }

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
      state = _withLocal(remote, state);
      await AppSettingsStorage.save(state);
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
      state = _withLocal(saved, next);
      await AppSettingsStorage.save(state);
    } catch (e) {
      if (mounted) state = previous;
      await AppSettingsStorage.save(previous);
      rethrow;
    }
  }

  Future<void> setScreenTimeout(ScreenTimeoutOption value) async {
    state = state.copyWith(screenTimeout: value);
    await AppSettingsStorage.save(state);
  }

  Future<void> setMenuOrder(List<String> value) async {
    if (listEquals(state.menuOrder, value)) return;
    state = state.copyWith(menuOrder: List<String>.from(value));
    await AppSettingsStorage.save(state);
  }

  Future<void> resetToDefaults() async {
    final timeout = state.screenTimeout;
    final order = state.menuOrder;
    state = FamilyChatAppSettings(
      screenTimeout: timeout,
      menuOrder: order,
    );
    await AppSettingsStorage.save(state);
  }
}
