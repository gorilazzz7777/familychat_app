import 'package:flutter/material.dart';

import '../../familychat/data/familychat_repository.dart';

/// Adding out-of-family contacts is disabled in UI.
/// Kept as no-ops so any leftover callers fail closed.
Future<void> runFriendInviteFlow(
  BuildContext context,
  FamilyChatRepository repo, {
  required bool hasIndividualPremium,
}) async {
  assert(() {
    // Keep signature stable for callers; values intentionally unused.
    return identical(repo, repo) && hasIndividualPremium == hasIndividualPremium;
  }());
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Добавление контактов вне семьи недоступно'),
    ),
  );
}

/// Fail-closed: never accept friend invites from deep links / pending tokens.
Future<Map<String, dynamic>?> confirmAndAcceptFriendInvite(
  BuildContext context,
  FamilyChatRepository repo,
  String token,
) async {
  assert(() {
    return identical(repo, repo) && token == token;
  }());
  if (!context.mounted) return null;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Добавление контактов вне семьи недоступно'),
    ),
  );
  return null;
}
