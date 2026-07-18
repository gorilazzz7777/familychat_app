import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gorila_chat/gorila_chat.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/token_storage.dart';

/// Family Chat [ChatHost] + capabilities wiring.
class FamilyChatHost implements ChatHost {
  FamilyChatHost(this._tokenStorage);

  final TokenStorage _tokenStorage;

  static const capabilities = ChatCapabilities.familyChat;

  @override
  Future<String?> readAccessToken() => _tokenStorage.readAccess();

  @override
  Color? get brandColor => null;

  @override
  Future<void> openUserProfile(
    BuildContext context, {
    required int userId,
  }) async {
    // Profile navigation stays in app screens; host is a stable extension point.
  }

  @override
  Future<void> openChatInfo(
    BuildContext context, {
    required int threadId,
  }) async {}
}

final familyChatHostProvider = Provider<FamilyChatHost>((ref) {
  return FamilyChatHost(ref.watch(apiClientProvider).tokenStorage);
});
