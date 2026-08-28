import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_actions_scope.dart';
import '../../familychat/data/familychat_repository.dart';
import '../../onboarding/presentation/family_transfer_flow.dart';
import '../../onboarding/presentation/onboarding_screen.dart';
import '../family_invite_share.dart';
import 'family_join_code_dialog.dart';
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
    await FamilyInviteShare.openScreen(context, relationshipCode: code);
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось создать приглашение: $e')),
    );
  }
}

Future<void> runJoinByInviteCodeFlow(
  BuildContext context,
  FamilyChatRepository repo,
) async {
  final code = await showFamilyJoinCodeDialog(context);
  if (code == null || !context.mounted) return;
  try {
    final resolved = await repo.resolveInviteCode(code);
    if (!context.mounted) return;
    if (resolved['valid'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Код не найден или уже не действует')),
      );
      return;
    }
    final token = (resolved['token']?.toString() ?? '').trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось принять приглашение')),
      );
      return;
    }
    final result = await confirmAndTransferFamilyInvite(context, repo, token);
    if (result == null || !context.mounted) return;
    if (result['needs_profile'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сначала заполните профиль, затем введите код снова'),
        ),
      );
      return;
    }
    final sessionId = result['onboarding_session_id'];
    if (sessionId != null) {
      final questions =
          (result['questions'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (ctx) => OnboardingScreen(
            onComplete: () => Navigator.of(ctx).pop(),
            onLogout: () => Navigator.of(ctx).pop(),
            transferSession: {
              'onboarding_session_id': sessionId,
              'questions': questions,
            },
          ),
        ),
      );
    }
    await AppActions.refreshStatus();
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Не удалось принять приглашение: $e')),
    );
  }
}

class FamilyAddMenuButton extends StatelessWidget {
  const FamilyAddMenuButton({super.key, required this.repo});

  final FamilyChatRepository repo;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.person_add_outlined),
      tooltip: 'Добавить в семью',
      onSelected: (value) {
        if (value == 'invite') {
          unawaited(runFamilyInviteFlow(context, repo));
        } else if (value == 'code') {
          unawaited(runJoinByInviteCodeFlow(context, repo));
        }
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(
          value: 'invite',
          child: Text('Пригласить в семью'),
        ),
        PopupMenuItem(
          value: 'code',
          child: Text('Ввести код приглашения'),
        ),
      ],
    );
  }
}
