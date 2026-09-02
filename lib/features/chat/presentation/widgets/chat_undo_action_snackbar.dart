import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/push/push_message_handler.dart';

/// Плавающий snackbar с кнопкой «Отменить» и обратным отсчётом в круге (как в Remont).
abstract final class ChatUndoActionSnackbar {
  static const defaultDuration = Duration(seconds: 3);

  /// [onCommit] вызывается после истечения [duration], если не нажали «Отменить».
  ///
  /// Возвращает [cancel] — отменить таймер и скрыть snackbar без [onCommit]
  /// (например при dispose экрана).
  static VoidCallback show(
    BuildContext context, {
    required String message,
    required VoidCallback onUndo,
    required Future<void> Function() onCommit,
    Duration duration = defaultDuration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context) ??
        familyChatScaffoldMessengerKey.currentState;
    if (messenger == null) {
      return () {};
    }

    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final undoActionTextColor = theme.brightness == Brightness.dark
        ? cs.primary
        : cs.inversePrimary;
    var cancelled = false;
    var notifierDisposed = false;
    final totalMs = duration.inMilliseconds;

    Timer? countdownTimer;
    final remainingNotifier = ValueNotifier<int>(totalMs);

    void scheduleDisposeNotifier() {
      if (notifierDisposed) return;
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (notifierDisposed) return;
        notifierDisposed = true;
        remainingNotifier.dispose();
      });
    }

    void hideSnackBar() {
      (familyChatScaffoldMessengerKey.currentState ?? messenger)
          .hideCurrentSnackBar();
      scheduleDisposeNotifier();
    }

    final timer = Timer(duration, () async {
      if (cancelled) return;
      countdownTimer?.cancel();
      hideSnackBar();
      if (!context.mounted) return;
      try {
        await onCommit();
      } catch (_) {
        // Ошибку показывает вызывающий код (onCommit).
      }
    });

    messenger.clearSnackBars();

    final startedAt = DateTime.now();
    if (totalMs > 0) {
      countdownTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) {
          if (cancelled) return;
          final elapsedMs =
              DateTime.now().difference(startedAt).inMilliseconds;
          final newRemaining = (totalMs - elapsedMs).clamp(0, totalMs);
          if (newRemaining <= 0) {
            countdownTimer?.cancel();
          }
          remainingNotifier.value = newRemaining;
        },
      );
    }

    void cancel({bool hide = true}) {
      if (cancelled) return;
      cancelled = true;
      timer.cancel();
      countdownTimer?.cancel();
      if (hide) {
        hideSnackBar();
      } else {
        scheduleDisposeNotifier();
      }
    }

    void onUndoPressed() {
      cancel();
      onUndo();
    }

    messenger.showSnackBar(
      SnackBar(
        backgroundColor: cs.inverseSurface,
        content: ValueListenableBuilder<int>(
          valueListenable: remainingNotifier,
          builder: (ctx, remainingMs, _) {
            final remainingSeconds =
                totalMs <= 0 ? 0 : (remainingMs / 1000).ceil();
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: totalMs <= 0
                              ? 0
                              : (remainingMs / totalMs).clamp(0, 1),
                          strokeWidth: 3,
                          backgroundColor: cs.error.withValues(alpha: 0.25),
                          valueColor: AlwaysStoppedAnimation<Color>(cs.error),
                        ),
                        Text(
                          '$remainingSeconds',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onInverseSurface),
                  ),
                ),
              ],
            );
          },
        ),
        action: SnackBarAction(
          label: 'Отменить',
          textColor: undoActionTextColor,
          onPressed: onUndoPressed,
        ),
        duration: duration,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );

    return cancel;
  }
}
