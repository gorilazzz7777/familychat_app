import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cache/familychat_media_cache.dart';
import '../media/media_cache_policy.dart';
import '../providers/app_providers.dart';
import 'app_settings.dart';
import 'app_settings_storage.dart';
import 'media_storage_options.dart';
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
      autoSaveIncomingToGallery: local.autoSaveIncomingToGallery,
      mediaCacheStale: local.mediaCacheStale,
      mediaCacheSize: local.mediaCacheSize,
    );
  }

  void _applyMediaPolicy(FamilyChatAppSettings settings) {
    MediaCachePolicy.apply(
      autoSaveIncomingToGallery: settings.autoSaveIncomingToGallery,
      stale: settings.mediaCacheStale,
      size: settings.mediaCacheSize,
    );
  }

  Future<void> _load() async {
    final local = await AppSettingsStorage.load();
    if (!mounted) return;
    state = local;
    _applyMediaPolicy(local);
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
      _applyMediaPolicy(state);
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
      _applyMediaPolicy(state);
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

  Future<void> setAutoSaveIncomingToGallery(bool value) async {
    state = state.copyWith(autoSaveIncomingToGallery: value);
    _applyMediaPolicy(state);
    await AppSettingsStorage.save(state);
  }

  Future<void> setMediaCacheStale(MediaCacheStaleOption value) async {
    state = state.copyWith(mediaCacheStale: value);
    _applyMediaPolicy(state);
    await AppSettingsStorage.save(state);
    unawaited(FamilyChatMediaCache.trimIfNeeded(force: true));
  }

  Future<void> setMediaCacheSize(MediaCacheSizeOption value) async {
    state = state.copyWith(mediaCacheSize: value);
    _applyMediaPolicy(state);
    await AppSettingsStorage.save(state);
    unawaited(FamilyChatMediaCache.trimIfNeeded(force: true));
  }

  Future<void> setMenuOrder(List<String> value) async {
    if (listEquals(state.menuOrder, value)) return;
    state = state.copyWith(menuOrder: List<String>.from(value));
    await AppSettingsStorage.save(state);
  }

  Future<void> resetToDefaults() async {
    final timeout = state.screenTimeout;
    final order = state.menuOrder;
    final autoSave = state.autoSaveIncomingToGallery;
    final stale = state.mediaCacheStale;
    final size = state.mediaCacheSize;
    state = FamilyChatAppSettings(
      screenTimeout: timeout,
      menuOrder: order,
      autoSaveIncomingToGallery: autoSave,
      mediaCacheStale: stale,
      mediaCacheSize: size,
    );
    await AppSettingsStorage.save(state);
  }
}
