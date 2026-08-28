import 'package:flutter/material.dart';

import '../../core/config/env.dart';
import 'presentation/family_invite_screen.dart';

/// Приглашение в семью: ссылка, QR и короткий цифровой код.
class FamilyInviteShare {
  FamilyInviteShare._();

  static String inviteUrlFromResponse(Map<String, dynamic> inv) {
    final full = (inv['invite_url']?.toString() ?? '').trim();
    if (full.isNotEmpty) return full;
    final path = inv['invite_url_path'] as String? ?? '';
    return '${Env.inviteBaseUrl}$path';
  }

  static String formatJoinCode(String code) {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 6) {
      return '${digits.substring(0, 3)} ${digits.substring(3)}';
    }
    return code.trim();
  }

  static String normalizeJoinCode(String raw) {
    return raw.replaceAll(RegExp(r'\D'), '');
  }

  static Future<void> openScreen(
    BuildContext context, {
    required String relationshipCode,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FamilyInviteScreen(relationshipCode: relationshipCode),
      ),
    );
  }
}
