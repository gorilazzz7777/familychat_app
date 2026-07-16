import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/config/env.dart';
import '../../familychat/data/familychat_repository.dart';

Future<void> runFriendInviteFlow(
  BuildContext context,
  FamilyChatRepository repo, {
  required bool hasIndividualPremium,
}) async {
  if (!hasIndividualPremium) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Individual Premium'),
        content: const Text(
          'Приглашение в личные контакты доступно только с Individual Premium. '
          'Принимать приглашение и переписываться может любой, '
          'пока у одного из вас активна подписка.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
    return;
  }
  try {
    final inv = await repo.createFriendInvite();
    if (!context.mounted) return;
    final url = inv['invite_url'] as String? ??
        '${Env.inviteBaseUrl}${inv['invite_url_path']}';
    await Share.share('Приглашение в контакты Family Chat: $url');
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось создать приглашение: $e')),
    );
  }
}

Future<Map<String, dynamic>?> confirmAndAcceptFriendInvite(
  BuildContext context,
  FamilyChatRepository repo,
  String token,
) async {
  try {
    final info = await repo.fetchFriendInviteInfo(token);
    if (!context.mounted) return null;
    final name = info['inviter_name']?.toString() ?? 'пользователя';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить в контакты?'),
        content: Text('Хотите добавить $name в контакты?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Нет'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Да'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    return await repo.acceptFriendInvite(token);
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось принять приглашение: $e')),
    );
    return null;
  }
}
