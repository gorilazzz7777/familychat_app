import 'package:flutter/material.dart';

/// Плавающий snackbar с кнопкой «Отменить» (как в Telegram / remont expense flow).
abstract final class ChatUndoActionSnackbar {
  static const defaultDuration = Duration(seconds: 5);

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason> show(
    BuildContext context, {
    required String message,
    required VoidCallback onUndo,
    Duration duration = defaultDuration,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: duration,
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: onUndo,
        ),
      ),
    );
  }
}
