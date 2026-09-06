import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/api_error_messages.dart';
import '../../../core/platform/app_foreground.dart';
import '../../../core/providers/app_providers.dart';
import '../data/auth_repository.dart';
import '../data/oauth_login_service.dart';

const googleRegistrationRestrictedRu = 'google_registration_restricted_ru';

class SocialAccountLinkResult {
  const SocialAccountLinkResult({
    required this.ok,
    this.googleRegistrationBlocked = false,
    this.error,
  });

  final bool ok;
  final bool googleRegistrationBlocked;
  final String? error;
}

Future<void> consumeOAuthSession({
  required AuthRepository auth,
  required String provider,
  required String sessionCode,
}) async {
  try {
    await auth.consumeSession(
      provider: provider,
      sessionCode: sessionCode,
    );
  } on DioException {
    if (!await auth.hasSession()) rethrow;
  }
}

Future<SocialAccountLinkResult> linkSocialAccount({
  required WidgetRef ref,
  required String provider,
}) async {
  final auth = ref.read(authRepositoryProvider);
  final oauth = OAuthLoginService();
  try {
    final result = await oauth.run(
      provider: provider,
      startUri: await auth.oauthStartUri(provider),
    );
    if (result['status'] != 'ok') {
      final errorCode = result['error_code'] ?? '';
      if (errorCode == googleRegistrationRestrictedRu) {
        return const SocialAccountLinkResult(
          ok: false,
          googleRegistrationBlocked: true,
        );
      }
      return SocialAccountLinkResult(
        ok: false,
        error: result['error'] ?? 'Вход отменён',
      );
    }
    await consumeOAuthSession(
      auth: auth,
      provider: provider,
      sessionCode: result['session_code']!,
    );
    await bringAppToForeground();
    return const SocialAccountLinkResult(ok: true);
  } catch (e) {
    return SocialAccountLinkResult(
      ok: false,
      error: userFacingErrorMessage(e),
    );
  }
}
