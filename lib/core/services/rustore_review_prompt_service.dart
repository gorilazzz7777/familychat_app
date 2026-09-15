import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../client/install_store.dart';
import '../config/env.dart';
import '../storage/app_rating_storage.dart';
import '../widgets/rustore_review_fallback_dialog.dart';

/// Оценка приложения: Play / RuStore In-App Review + запасной диалог.
///
/// Триггеры (как раньше): 10-я сессия и первая реакция в ленте.
/// Выбор SDK по installer (как в Remont): Play → Play Review, RuStore → RuStore,
/// иначе — сразу fallback (каталог Play, если установлен, иначе RuStore).
class RuStoreReviewPromptService {
  static const String _logName = 'StoreReviewPrompt';

  static const MethodChannel _rustoreReviewChannel =
      MethodChannel('com.familychat.familychat_app/rustore_review');
  static const MethodChannel _playReviewChannel =
      MethodChannel('com.familychat.familychat_app/play_review');

  static const int _sessionTriggerCount = 10;

  static const Duration _minPlausibleReviewDuration =
      Duration(milliseconds: 700);
  static const Duration _sdkCallTimeout = Duration(minutes: 11);

  static const String _completedKey = 'familychat_rustore_review_done_v1';
  static const String _sessionCountKey = 'familychat_app_session_count_v1';
  static const String _firstLikePromptedKey =
      'familychat_first_like_review_prompted_v1';
  static const String _sessionPromptFiredKey =
      'familychat_session10_review_prompted_v1';

  static bool _promptInFlight = false;
  static bool _wasBackgrounded = false;
  static DateTime? _lastSessionCountedAt;

  static const Duration _minSessionGap = Duration(seconds: 30);

  static final Uri _ruStoreAppUri = Uri.parse(Env.rustoreAppUrl);
  static final Uri _playStoreAppUri = Uri.parse(Env.playStoreAppUrl);

  static void _log(String message, {Object? error, StackTrace? stackTrace}) {
    debugPrint('[$_logName] $message');
    developer.log(
      message,
      name: _logName,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void _snack(BuildContext context, String text) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  static Future<bool> _isCompleted(SharedPreferences prefs) async {
    if (prefs.getBool(_completedKey) == true) return true;
    final stars = await AppRatingStorage.submittedStars();
    return stars != null;
  }

  static Future<void> _markCompleted(SharedPreferences prefs) async {
    await prefs.setBool(_completedKey, true);
  }

  static Future<void> _reportSdkFailure(
    FamilyChatRepository repository, {
    required String stage,
    required String errorCode,
    String? errorMessage,
    String? reason,
    String? details,
  }) async {
    _log(
      'SDK failure stage=$stage code=$errorCode message=$errorMessage reason=$reason',
    );
    await repository.reportRustoreReviewError(
      stage: stage,
      errorCode: errorCode,
      errorMessage: errorMessage,
      reason: reason,
      details: details,
    );
  }

  static bool _isAlreadyReviewedError(Map native) {
    final code = '${native['error_code'] ?? ''}'.toLowerCase();
    final message = '${native['error_message'] ?? ''}'.toLowerCase();
    final combined = '$code $message';
    return combined.contains('reviewexists') ||
        combined.contains('review_exists') ||
        combined.contains('already reviewed') ||
        combined.contains('already_rated');
  }

  static Future<_InstallStoreKind> _detectInstallStore() async {
    final store = await InstallStore.resolve();
    switch (store) {
      case InstallStore.play:
        return _InstallStoreKind.play;
      case InstallStore.rustore:
        return _InstallStoreKind.rustore;
      default:
        return _InstallStoreKind.unknown;
    }
  }

  /// Для unknown installer: Play если приложение Play установлено, иначе RuStore.
  static Future<_CatalogTarget> _resolveFallbackCatalog(
    _InstallStoreKind preferred,
  ) async {
    if (preferred == _InstallStoreKind.play) {
      return _CatalogTarget.play;
    }
    if (preferred == _InstallStoreKind.rustore) {
      return _CatalogTarget.rustore;
    }
    try {
      final native = await _playReviewChannel
          .invokeMethod<dynamic>('getReviewDiagnostics')
          .timeout(const Duration(seconds: 3));
      if (native is Map) {
        final diag = native['diagnostics'];
        if (diag is Map && diag['play_installed'] == true) {
          return _CatalogTarget.play;
        }
      }
    } catch (_) {}
    return _CatalogTarget.rustore;
  }

  static Future<_SdkReviewOutcome> _tryStoreInAppReview(
    FamilyChatRepository repository, {
    required String reason,
    required String storeSdk,
    required MethodChannel channel,
    required String launchMethod,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final dynamic native = await channel
          .invokeMethod(launchMethod)
          .timeout(_sdkCallTimeout);
      sw.stop();
      _log(
        '$storeSdk SDK invokeMethod result: $native (${native.runtimeType}) '
        'elapsedMs=${sw.elapsedMilliseconds}',
      );

      if (native == true || (native is Map && native['ok'] == true)) {
        final uiAppeared = native is Map && native['ui_appeared'] == true;
        if (!uiAppeared && sw.elapsed < _minPlausibleReviewDuration) {
          await _reportSdkFailure(
            repository,
            stage: '$storeSdk/launchReviewFlow',
            errorCode: 'suspiciously_fast_success',
            errorMessage:
                'SDK returned ok in ${sw.elapsedMilliseconds}ms — UI likely skipped',
            reason: reason,
            details: '$native',
          );
          return _SdkReviewOutcome.silentOrFailed;
        }
        return _SdkReviewOutcome.completedWithUi;
      }

      if (native is Map) {
        if (_isAlreadyReviewedError(native)) {
          await _reportSdkFailure(
            repository,
            stage: '$storeSdk/${native['stage'] ?? 'unknown'}',
            errorCode: '${native['error_code'] ?? 'ReviewExists'}',
            errorMessage: native['error_message']?.toString(),
            reason: reason,
            details: '$native',
          );
          return _SdkReviewOutcome.alreadyReviewed;
        }
        await _reportSdkFailure(
          repository,
          stage: '$storeSdk/${native['stage'] ?? 'unknown'}',
          errorCode: '${native['error_code'] ?? 'unknown'}',
          errorMessage: native['error_message']?.toString(),
          reason: reason,
          details: '$native',
        );
        if (native['fallback_allowed'] == false) {
          return _SdkReviewOutcome.abortedNoFallback;
        }
        return _SdkReviewOutcome.silentOrFailed;
      }

      await _reportSdkFailure(
        repository,
        stage: '$storeSdk/invoke',
        errorCode: 'unexpected_result',
        errorMessage: '${native.runtimeType}: $native',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    } on TimeoutException catch (e) {
      sw.stop();
      await _reportSdkFailure(
        repository,
        stage: '$storeSdk/timeout',
        errorCode: 'TimeoutException',
        errorMessage:
            'No SDK response within ${_sdkCallTimeout.inMinutes}min: $e',
        reason: reason,
      );
      return _SdkReviewOutcome.abortedNoFallback;
    } on MissingPluginException catch (e) {
      await _reportSdkFailure(
        repository,
        stage: '$storeSdk/plugin',
        errorCode: 'MissingPluginException',
        errorMessage: '$e',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    } on PlatformException catch (e, st) {
      _log(
        '$storeSdk SDK PlatformException code=${e.code} message=${e.message}',
        error: e,
        stackTrace: st,
      );
      await _reportSdkFailure(
        repository,
        stage: '$storeSdk/platform',
        errorCode: e.code,
        errorMessage: e.message,
        reason: reason,
        details: e.details?.toString(),
      );
      return _SdkReviewOutcome.silentOrFailed;
    } catch (e) {
      await _reportSdkFailure(
        repository,
        stage: '$storeSdk/dart',
        errorCode: e.runtimeType.toString(),
        errorMessage: '$e',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    }
  }

  static Future<void> _openCatalog(Uri uri, String label) async {
    if (uri.toString().trim().isEmpty) {
      _log('fallback: $label url empty');
      return;
    }
    if (!await canLaunchUrl(uri)) {
      _log('fallback: canLaunchUrl=false for $uri');
      return;
    }
    final ok = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    _log('$label catalog launch: ok=$ok');
  }

  static Future<void> _submitRatingAndRedirect({
    required FamilyChatRepository repository,
    required SharedPreferences prefs,
    required int stars,
    required BuildContext context,
    required _CatalogTarget catalog,
  }) async {
    final source = catalog == _CatalogTarget.play
        ? 'play_prompt'
        : 'rustore_prompt';
    await repository.submitAppRating(stars, source: source);
    await AppRatingStorage.saveSubmitted(stars);
    await _markCompleted(prefs);
    _log('rating submitted: $stars stars → ${catalog.label}');
    if (!context.mounted) return;
    _snack(context, 'Спасибо! Открываем ${catalog.label}…');
    await _openCatalog(catalog.uri, catalog.label);
  }

  static Future<void> maybePrompt(
    BuildContext context, {
    required FamilyChatRepository repository,
    required String reason,
  }) async {
    if (!Platform.isAndroid) {
      _log('skip: not Android ($reason)');
      return;
    }
    if (_promptInFlight) {
      _log('skip: prompt already in flight ($reason)');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (await _isCompleted(prefs)) {
      _log('skip: already completed ($reason)');
      return;
    }

    _promptInFlight = true;
    try {
      if (!context.mounted) return;

      final installStore = await _detectInstallStore();
      final catalog = await _resolveFallbackCatalog(installStore);

      _SdkReviewOutcome outcome;
      String? successChannel;

      switch (installStore) {
        case _InstallStoreKind.play:
          _snack(context, 'Сейчас откроется оценка приложения в Google Play.');
          outcome = await _tryStoreInAppReview(
            repository,
            reason: reason,
            storeSdk: 'play',
            channel: _playReviewChannel,
            launchMethod: 'launchPlayReview',
          );
          successChannel = 'play';
          break;
        case _InstallStoreKind.rustore:
          _snack(context, 'Сейчас откроется оценка приложения в RuStore.');
          outcome = await _tryStoreInAppReview(
            repository,
            reason: reason,
            storeSdk: 'rustore',
            channel: _rustoreReviewChannel,
            launchMethod: 'launchRuStoreReview',
          );
          successChannel = 'rustore';
          break;
        case _InstallStoreKind.unknown:
          _log('unknown installer — skip store SDK, show fallback');
          outcome = _SdkReviewOutcome.silentOrFailed;
          break;
      }

      if (outcome == _SdkReviewOutcome.completedWithUi) {
        await repository.reportAppRatingPromptShown(successChannel ?? 'fallback');
        await _markCompleted(prefs);
        _log(
          'marked completed (${successChannel ?? 'store'} In-App review) '
          'reason=$reason',
        );
        return;
      }
      if (outcome == _SdkReviewOutcome.alreadyReviewed) {
        await _markCompleted(prefs);
        _log('already reviewed in store — completed, skip fallback reason=$reason');
        return;
      }
      if (outcome == _SdkReviewOutcome.abortedNoFallback) {
        _log(
          'In-App flow still in progress or UI was shown — '
          'skip fallback reason=$reason',
        );
        return;
      }

      _log('In-App SDK did not complete — showing stars dialog → ${catalog.label}');
      if (!context.mounted) return;
      await repository.reportAppRatingPromptShown('fallback');
      await showRustoreReviewFallbackDialog(
        context,
        storeCatalogName: catalog.label,
        onSubmit: (stars) => _submitRatingAndRedirect(
          repository: repository,
          prefs: prefs,
          stars: stars,
          context: context,
          catalog: catalog,
        ),
      );
    } finally {
      _promptInFlight = false;
    }
  }

  static void onAppPaused() {
    _wasBackgrounded = true;
  }

  static Future<void> onAppSessionOpened(
    BuildContext context, {
    required FamilyChatRepository repository,
    bool fromColdStart = false,
  }) async {
    if (!fromColdStart && !_wasBackgrounded) {
      _log('skip session: resume without background');
      return;
    }
    _wasBackgrounded = false;

    final now = DateTime.now();
    final last = _lastSessionCountedAt;
    if (last != null && now.difference(last) < _minSessionGap) {
      _log('skip session: within ${_minSessionGap.inSeconds}s of previous');
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (await _isCompleted(prefs)) return;

    _lastSessionCountedAt = now;
    final next = (prefs.getInt(_sessionCountKey) ?? 0) + 1;
    await prefs.setInt(_sessionCountKey, next);
    _log('session count=$next (trigger at $_sessionTriggerCount)');

    if (next != _sessionTriggerCount) return;
    if (prefs.getBool(_sessionPromptFiredKey) == true) {
      _log('skip: session10 prompt already fired');
      return;
    }
    await prefs.setBool(_sessionPromptFiredKey, true);
    if (!context.mounted) return;
    await maybePrompt(
      context,
      repository: repository,
      reason: 'session_$next',
    );
  }

  static Future<void> onFirstFeedLike(
    BuildContext context, {
    required FamilyChatRepository repository,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (await _isCompleted(prefs)) return;
    if (prefs.getBool(_firstLikePromptedKey) == true) {
      _log('skip: first-like prompt already fired');
      return;
    }
    await prefs.setBool(_firstLikePromptedKey, true);
    if (!context.mounted) return;
    await maybePrompt(
      context,
      repository: repository,
      reason: 'first_feed_like',
    );
  }
}

enum _InstallStoreKind { play, rustore, unknown }

enum _SdkReviewOutcome {
  completedWithUi,
  silentOrFailed,
  abortedNoFallback,
  alreadyReviewed,
}

enum _CatalogTarget {
  play,
  rustore;

  String get label => switch (this) {
        play => 'Google Play',
        rustore => 'RuStore',
      };

  Uri get uri => switch (this) {
        play => RuStoreReviewPromptService._playStoreAppUri,
        rustore => RuStoreReviewPromptService._ruStoreAppUri,
      };
}
