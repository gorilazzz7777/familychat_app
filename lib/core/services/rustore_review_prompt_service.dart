import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/familychat/data/familychat_repository.dart';
import '../config/env.dart';
import '../storage/app_rating_storage.dart';
import '../widgets/rustore_review_fallback_dialog.dart';

/// RuStore: просьба оценить приложение.
///
/// Триггеры: 10-я сессия и первая реакция в ленте.
/// Если пользователь уже оценил — больше не просим.
class RuStoreReviewPromptService {
  static const String _logName = 'RuStoreReviewPrompt';

  static const MethodChannel _androidReviewChannel =
      MethodChannel('com.familychat.familychat_app/rustore_review');

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

  static Future<_SdkReviewOutcome> _tryRustoreInAppReview(
    FamilyChatRepository repository, {
    required String reason,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final dynamic native = await _androidReviewChannel
          .invokeMethod('launchRuStoreReview')
          .timeout(_sdkCallTimeout);
      sw.stop();
      _log(
        'RuStore SDK invokeMethod result: $native (${native.runtimeType}) '
        'elapsedMs=${sw.elapsedMilliseconds}',
      );

      if (native == true || (native is Map && native['ok'] == true)) {
        final uiAppeared = native is Map && native['ui_appeared'] == true;
        if (!uiAppeared && sw.elapsed < _minPlausibleReviewDuration) {
          await _reportSdkFailure(
            repository,
            stage: 'launchReviewFlow',
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
        await _reportSdkFailure(
          repository,
          stage: '${native['stage'] ?? 'unknown'}',
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
        stage: 'invoke',
        errorCode: 'unexpected_result',
        errorMessage: '${native.runtimeType}: $native',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    } on TimeoutException catch (e) {
      sw.stop();
      await _reportSdkFailure(
        repository,
        stage: 'timeout',
        errorCode: 'TimeoutException',
        errorMessage:
            'No SDK response within ${_sdkCallTimeout.inMinutes}min: $e',
        reason: reason,
      );
      return _SdkReviewOutcome.abortedNoFallback;
    } on MissingPluginException catch (e) {
      await _reportSdkFailure(
        repository,
        stage: 'plugin',
        errorCode: 'MissingPluginException',
        errorMessage: '$e',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    } on PlatformException catch (e, st) {
      _log(
        'RuStore SDK PlatformException code=${e.code} message=${e.message}',
        error: e,
        stackTrace: st,
      );
      await _reportSdkFailure(
        repository,
        stage: 'platform',
        errorCode: e.code,
        errorMessage: e.message,
        reason: reason,
        details: e.details?.toString(),
      );
      return _SdkReviewOutcome.silentOrFailed;
    } catch (e) {
      await _reportSdkFailure(
        repository,
        stage: 'dart',
        errorCode: e.runtimeType.toString(),
        errorMessage: '$e',
        reason: reason,
      );
      return _SdkReviewOutcome.silentOrFailed;
    }
  }

  static Future<void> _openRuStoreCatalog() async {
    if (Env.rustoreAppUrl.trim().isEmpty) {
      _log('fallback: rustoreAppUrl empty');
      return;
    }
    if (!await canLaunchUrl(_ruStoreAppUri)) {
      _log('fallback: canLaunchUrl=false for $_ruStoreAppUri');
      return;
    }
    final ok = await launchUrl(
      _ruStoreAppUri,
      mode: LaunchMode.externalApplication,
    );
    _log('RuStore catalog launch: ok=$ok');
  }

  static Future<void> _submitRatingAndRedirect({
    required FamilyChatRepository repository,
    required SharedPreferences prefs,
    required int stars,
    required BuildContext context,
  }) async {
    await repository.submitAppRating(stars);
    await AppRatingStorage.saveSubmitted(stars);
    await _markCompleted(prefs);
    _log('rating submitted: $stars stars');
    if (!context.mounted) return;
    _snack(context, 'Спасибо! Открываем RuStore…');
    await _openRuStoreCatalog();
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
      _snack(context, 'Сейчас откроется оценка приложения в RuStore.');

      final outcome = await _tryRustoreInAppReview(
        repository,
        reason: reason,
      );
      if (outcome == _SdkReviewOutcome.completedWithUi) {
        await repository.reportAppRatingPromptShown('rustore');
        await _markCompleted(prefs);
        _log('marked completed (RuStore In-App review) reason=$reason');
        return;
      }
      if (outcome == _SdkReviewOutcome.abortedNoFallback) {
        _log(
          'RuStore In-App flow still in progress or UI was shown — '
          'skip fallback reason=$reason',
        );
        return;
      }

      _log('RuStore In-App SDK did not complete — showing stars dialog');
      if (!context.mounted) return;
      await repository.reportAppRatingPromptShown('fallback');
      await showRustoreReviewFallbackDialog(
        context,
        onSubmit: (stars) => _submitRatingAndRedirect(
          repository: repository,
          prefs: prefs,
          stars: stars,
          context: context,
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

enum _SdkReviewOutcome {
  completedWithUi,
  silentOrFailed,
  abortedNoFallback,
}
