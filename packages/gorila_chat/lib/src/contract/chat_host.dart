import 'package:flutter/material.dart';

/// App-owned hooks: navigation, auth token, theming beyond Material defaults.
abstract class ChatHost {
  /// Current access JWT for HTTP / WebSocket.
  Future<String?> readAccessToken();

  /// Open member / user profile from a chat context.
  Future<void> openUserProfile(BuildContext context, {required int userId});

  /// Optional brand accent; null → Theme.of(context).colorScheme.primary.
  Color? get brandColor => null;

  /// Navigator key for incoming-call fullscreen routes (and similar).
  GlobalKey<NavigatorState>? get navigatorKey => null;
}
