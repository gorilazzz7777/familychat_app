import 'package:flutter/material.dart';

import '../../familychat/data/familychat_repository.dart';

/// Диалог подтверждения перехода в другую семью.
/// Возвращает результат `acceptInvite` с `confirm_transfer`, либо null.
Future<Map<String, dynamic>?> confirmAndTransferFamilyInvite(
  BuildContext context,
  FamilyChatRepository repo,
  String token,
) async {
  try {
    final probe = await repo.acceptInvite(token);
    if (!context.mounted) return null;

    if (probe['needs_transfer_confirm'] != true) {
      // Уже в целевой семье или нет активной семьи — передаём как есть.
      return probe;
    }

    final current = probe['current_family_name']?.toString() ?? 'текущей семьи';
    final target = probe['target_family_name']?.toString() ?? 'новой семьи';
    final sole = probe['sole_member'] == true;
    final warning = sole
        ? 'Вы единственный участник «$current». После перехода эта семья '
            'и её данные будут удалены безвозвратно.\n\n'
            'Перейти в «$target»?'
        : 'Вы покинете «$current» и перейдёте в «$target».\n\n'
            '• Семейный чат и группы старой семьи исчезнут из списка\n'
            '• Личные переписки останутся только для чтения\n'
            '• Друзья и их чаты не изменятся\n\n'
            'Продолжить?';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переход в другую семью'),
        content: Text(warning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(sole ? 'Удалить и перейти' : 'Перейти'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return null;
    return await repo.acceptInvite(token, confirmTransfer: true);
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось принять приглашение: $e')),
    );
    return null;
  }
}
