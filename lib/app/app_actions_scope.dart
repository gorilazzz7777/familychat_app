import 'dart:async';

import 'package:flutter/material.dart';

import '../features/profile/presentation/profile_screen.dart';

/// Сессия приложения: профиль и выход доступны с любого экрана (в т.ч. push-маршрутов).
abstract final class AppActions {
  static Map<String, dynamic> _status = {};
  static Future<void> Function() _onLogout = () async {};
  static Future<void> Function() _onStatusChanged = () async {};

  static void bind({
    required Map<String, dynamic> status,
    required Future<void> Function() onLogout,
    required Future<void> Function() onStatusChanged,
  }) {
    _status = status;
    _onLogout = onLogout;
    _onStatusChanged = onStatusChanged;
  }

  static String get displayName => _status['display_name']?.toString() ?? '';
  static String get avatarUrl => _status['avatar_url']?.toString() ?? '';

  static Future<void> openProfile(BuildContext context) async {
    if (_status.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ProfileScreen(
          status: _status,
          onLogout: _onLogout,
          onStatusChanged: () {
            unawaited(_onStatusChanged());
          },
        ),
      ),
    );
  }
}
