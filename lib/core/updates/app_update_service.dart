import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rustore_update/flutter_rustore_update.dart'
    hide UpdateAvailability, InstallStatus;
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/env.dart';
import 'app_distribution_store.dart';
import 'store_resolver.dart';

/// Soft in-app update: check store → prompt → download in background → apply.
class AppUpdateService {
  AppUpdateService._();

  static const _softDismissKey = 'familychat_app_update_soft_dismiss_at';
  static const _softDismissDays = 3;

  static bool _checkInFlight = false;
  static bool _listenerAttached = false;
  static StreamSubscription<RequestResponse>? _rustoreSub;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _isIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> _isSoftDismissActive() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_softDismissKey);
    if (raw == null || raw.isEmpty) return false;
    final at = DateTime.tryParse(raw);
    if (at == null) return false;
    return DateTime.now().difference(at) <
        const Duration(days: _softDismissDays);
  }

  static Future<void> softDismiss() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_softDismissKey, DateTime.now().toIso8601String());
  }

  /// Call after shell is ready (once per cold start).
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kIsWeb || _checkInFlight) return;
    if (!context.mounted) return;
    if (await _isSoftDismissActive()) return;

    _checkInFlight = true;
    try {
      final store = await StoreResolver.resolve();
      debugPrint('[AppUpdate] store=$store define=${Env.storeTarget}');

      if (!context.mounted) return;
      switch (store) {
        case AppDistributionStore.rustore:
          await _checkRustore(context);
        case AppDistributionStore.play:
          await _checkPlay(context);
        case AppDistributionStore.appstore:
          await _checkAppStore(context);
        case AppDistributionStore.unknown:
          if (_isAndroid) {
            final rustore = await _rustoreUpdateAvailable();
            if (!context.mounted) return;
            if (rustore) {
              await _checkRustore(context);
              return;
            }
            await _checkPlay(context);
          }
      }
    } catch (e, st) {
      debugPrint('[AppUpdate] check failed: $e\n$st');
    } finally {
      _checkInFlight = false;
    }
  }

  static Future<bool> _showPrompt(
    BuildContext context, {
    required AppDistributionStore store,
  }) async {
    if (!context.mounted) return false;
    final action = await showDialog<_UpdateDialogAction>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final isIos = store == AppDistributionStore.appstore;
        return AlertDialog(
          title: const Text('Доступно обновление'),
          content: Text(
            isIos
                ? 'Вышла новая версия Family Chat.\n'
                    'Нажмите «Обновить», чтобы открыть ${store.label}.'
                : 'Вышла новая версия Family Chat.\n'
                    'Можно обновить через ${store.label} — скачивание пойдёт '
                    'в фоне, работа в приложении не прервётся.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _UpdateDialogAction.later),
              child: const Text('Позже'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, _UpdateDialogAction.update),
              child: const Text('Обновить'),
            ),
          ],
        );
      },
    );
    if (action == _UpdateDialogAction.later) {
      await softDismiss();
      return false;
    }
    return action == _UpdateDialogAction.update;
  }

  static void _snack(
    BuildContext context,
    String text, {
    SnackBarAction? action,
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: action == null
            ? const Duration(seconds: 4)
            : const Duration(days: 1),
        action: action,
      ),
    );
  }

  static Future<bool> _rustoreUpdateAvailable() async {
    if (!_isAndroid) return false;
    try {
      final info = await RustoreUpdateClient.info();
      return info.updateAvailability == UPDATE_AVAILABILITY_AVAILABLE;
    } catch (e) {
      debugPrint('[AppUpdate] rustore info: $e');
      return false;
    }
  }

  static Future<void> _checkRustore(BuildContext context) async {
    if (!_isAndroid) return;
    final available = await _rustoreUpdateAvailable();
    if (!available || !context.mounted) return;

    final ok = await _showPrompt(context, store: AppDistributionStore.rustore);
    if (!ok || !context.mounted) return;

    _ensureRustoreListener(context);
    try {
      final result = await RustoreUpdateClient.silent();
      debugPrint('[AppUpdate] rustore silent code=${result.code}');
      if (result.code == ACTIVITY_RESULT_OK && context.mounted) {
        _snack(context, 'Обновление скачивается в фоне…');
      }
    } catch (e) {
      debugPrint('[AppUpdate] rustore silent failed: $e');
      await _openUrl(Env.rustoreAppUrl);
    }
  }

  static void _ensureRustoreListener(BuildContext context) {
    if (_listenerAttached) return;
    _listenerAttached = true;
    _rustoreSub?.cancel();
    _rustoreSub = RustoreUpdateClient.stateStream.listen((value) {
      debugPrint(
        '[AppUpdate] rustore status=${value.installStatus} '
        'bytes=${value.bytesDownloaded}/${value.totalBytesToDownload}',
      );
      if (value.installStatus == INSTALL_STATUS_DOWNLOADED) {
        if (!context.mounted) return;
        _snack(
          context,
          'Обновление скачано. Можно установить.',
          action: SnackBarAction(
            label: 'Установить',
            onPressed: () {
              unawaited(_completeRustoreFlexible());
            },
          ),
        );
      }
    });
  }

  static Future<void> _completeRustoreFlexible() async {
    try {
      await RustoreUpdateClient.completeUpdateFlexible();
    } catch (e) {
      debugPrint('[AppUpdate] rustore complete: $e');
    }
  }

  static Future<void> _checkPlay(BuildContext context) async {
    if (!_isAndroid) return;
    try {
      final info = await InAppUpdate.checkForUpdate();
      final available =
          info.updateAvailability == UpdateAvailability.updateAvailable;
      if (!available || !context.mounted) return;

      final ok = await _showPrompt(context, store: AppDistributionStore.play);
      if (!ok || !context.mounted) return;

      if (info.flexibleUpdateAllowed) {
        final result = await InAppUpdate.startFlexibleUpdate();
        if (result == AppUpdateResult.success && context.mounted) {
          _snack(
            context,
            'Обновление скачано. Можно установить.',
            action: SnackBarAction(
              label: 'Установить',
              onPressed: () {
                unawaited(InAppUpdate.completeFlexibleUpdate());
              },
            ),
          );
        }
      } else if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      } else {
        await _openUrl(Env.playStoreAppUrl);
      }
    } catch (e) {
      debugPrint('[AppUpdate] play check/update: $e');
      await _openUrl(Env.playStoreAppUrl);
    }
  }

  static Future<void> _checkAppStore(BuildContext context) async {
    if (!_isIos) return;
    try {
      final package = await PackageInfo.fromPlatform();
      final lookup = await _appStoreLookup(package.packageName);
      if (lookup == null) return;
      final remote = lookup['version']?.toString() ?? '';
      if (remote.isEmpty) return;
      if (!_isRemoteNewer(local: package.version, remote: remote)) return;
      if (!context.mounted) return;

      final ok =
          await _showPrompt(context, store: AppDistributionStore.appstore);
      if (!ok) return;

      final trackViewUrl = lookup['trackViewUrl']?.toString().trim() ?? '';
      final configured = Env.appStoreAppUrl.trim();
      final url = (configured.isNotEmpty && !configured.contains('id000000000'))
          ? configured
          : trackViewUrl;
      if (url.isEmpty) {
        debugPrint('[AppUpdate] App Store URL empty');
        return;
      }
      await _openUrl(url);
    } catch (e) {
      debugPrint('[AppUpdate] appstore: $e');
    }
  }

  static Future<Map<String, dynamic>?> _appStoreLookup(String bundleId) async {
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'bundleId': bundleId,
      'country': 'ru',
    });
    try {
      final res = await Dio().getUri(
        uri,
        options: Options(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
        ),
      );
      final decoded = res.data;
      if (decoded is! Map) return null;
      final results = decoded['results'];
      if (results is! List || results.isEmpty) return null;
      final first = results.first;
      if (first is Map<String, dynamic>) return first;
      if (first is Map) return Map<String, dynamic>.from(first);
      return null;
    } catch (e) {
      debugPrint('[AppUpdate] itunes lookup: $e');
      return null;
    }
  }

  static bool _isRemoteNewer({required String local, required String remote}) {
    List<int> parts(String v) => v
        .split(RegExp(r'[^0-9]+'))
        .where((e) => e.isNotEmpty)
        .map(int.parse)
        .toList();
    final a = parts(local);
    final b = parts(remote);
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (y > x) return true;
      if (y < x) return false;
    }
    return false;
  }

  static Future<void> _openUrl(String raw) async {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

enum _UpdateDialogAction { later, update }
