import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/env.dart';
import '../../familychat/data/familychat_repository.dart';
import 'invite_kinship_dialog.dart';

Future<void> runFamilyInviteFlow(
  BuildContext context,
  FamilyChatRepository repo,
) async {
  try {
    final options = await repo.kinshipOptions();
    if (!context.mounted) return;
    final code = await showInviteKinshipDialog(context, options: options);
    if (code == null || !context.mounted) return;
    final inv = await repo.createInvite(code);
    final url = inv['invite_url'] as String? ??
        '${Env.inviteBaseUrl}${inv['invite_url_path']}';
    await Share.share('Приглашение в Family Chat: $url');
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось создать приглашение: $e')),
    );
  }
}
